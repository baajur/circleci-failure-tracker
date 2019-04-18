import re
import os
import threading
from concurrent.futures import ThreadPoolExecutor
import urllib.parse
import json
import requests

import myutils
import sql.sqlread as sqlread
import sql.sqlwrite as sqlwrite
import circlefetch
import requests_cache


CACHE_LOGS_TO_DISK = True


MAX_NETWORK_THREADS = 8


class CounterWrapper:
    def __init__(self):
        self.val = 0
        self.counter_lock = threading.Lock()

    def atomic_increment(self, count=1):
        with self.counter_lock:
            self.val += count


def populate_builds(engine, options):

    earliest_date_limit = 0
    earliest_date_found = float("inf")

    counter_wrapper = CounterWrapper()

    engine.logger.log("Populating builds list...")

    # FIXME
    # while counter_wrapper.val < 300 or earliest_date_found > earliest_date_limit:
    while counter_wrapper.val < options.count:

        def callback(r_json):

            values_to_insert = []
            for build in r_json:
                vals = (
                    build["build_num"],
                    build["vcs_revision"],
                    build["queued_at"],
                    build["workflows"]["job_name"],
                )

                values_to_insert.append(vals)

            sqlwrite.insert_builds(engine.conn, values_to_insert)
            counter_wrapper.atomic_increment(len(values_to_insert))

        r = requests.get("/".join([
                circlefetch.CIRCLECI_API_BASE,
                "tree",
                urllib.parse.quote(options.branch),
            ]), params=circlefetch.get_parms(options.token, offset=counter_wrapper.val))

        engine.logger.log("Fetch builds starting at offset %d..." % counter_wrapper.val)

        circlefetch.get_json_or_fail(r, callback, "Build list fetch failed for branch: " + options.branch)

        # TODO
        earliest_date_found = earliest_date_limit


def get_matches(engine, regular_expressions, output_url, cache_key):

    def callback(r_json):

        message_raw = r_json[0]["message"]

        split_message_lines = message_raw.splitlines()
        line_count = len(split_message_lines)

        matches = []
        for i, line in enumerate(split_message_lines):

            for pattern_id, is_regex, regex_or_literal, description in regular_expressions:

                if is_regex:
                    match_object = regex_or_literal.search(line)

                    if match_object:
                        match_tuple = (pattern_id, i, line, match_object.span())
                        matches.append(match_tuple)

                else:
                    found_index = line.find(regex_or_literal)

                    if found_index >= 0:
                        match_tuple = (pattern_id, i, line, (found_index, found_index + len(regex_or_literal)))
                        matches.append(match_tuple)

        return line_count, matches

    return from_cache_or_download(engine, output_url, cache_key, callback)


def from_cache_or_download(engine, url, cache_key, callback):
    """
    NOTE: We cannot cache the AWS URL, because it changes with the signature.
    Instead, we cache based on the parameters that were used to request the AWS URL.
    """

    url_cache_basedir = os.path.join(os.path.dirname(__file__), "download-cache")

    import hashlib
    m = hashlib.md5()
    m.update(cache_key.encode('utf-8'))

    filepath = os.path.join(url_cache_basedir, m.hexdigest())
    if CACHE_LOGS_TO_DISK and os.path.isfile(filepath):
        with open(filepath) as fh:
            return callback(json.load(fh))
    else:
        engine.logger.log("Downloading from:", url)

        s = requests.Session()
        r = s.get(url)

        result = circlefetch.get_json_or_fail(r, callback, "Console output fetch failed for URL: " + url)

        if CACHE_LOGS_TO_DISK:
            os.makedirs(url_cache_basedir, exist_ok=True)
            with open(filepath, "w") as fh:
                fh.write(r.text)

        return result


# TODO This doesn't need to return a list;
# Perhaps the database schema could also be updated to combine the "build steps" table
# and the "builds" table?
def get_failed_build_step(engine, regular_expressions, r_url, r_json):
    for step in r_json["steps"]:
        build_step_name = step["name"]
        for action in step["actions"]:

            if action.get("failed"):

                output_url = action.get("output_url")

                if output_url:
                    line_count, matches = get_matches(engine, regular_expressions, output_url, r_url + build_step_name)
                    return [(build_step_name, False, (line_count, matches))]

                else:
                    engine.logger.warn(
                        'WARNING: No output URL for build step "%s", from JSON at URL: %s\n' % (build_step_name, r_url))

            elif action.get("timedout"):
                return [(build_step_name, True, (0, []))]

    return []


def search_log(engine, api_token, patterns_by_id, unscanned_pattern_ids, build_number):

    regular_expressions = []
    for pattern_id in unscanned_pattern_ids:
        is_regex, pattern, description = patterns_by_id[pattern_id]

        compiled_pattern = re.compile(pattern) if is_regex else pattern
        regular_expressions.append((pattern_id, is_regex, compiled_pattern, description))

    r_url = "/".join([circlefetch.CIRCLECI_API_BASE, str(build_number)])

    s = requests_cache.core.CachedSession() if CACHE_LOGS_TO_DISK else requests.Session()
    r = s.get(r_url, params={"circle-token": api_token})

    def callback(r_json):

        build_step_failure_tuples = get_failed_build_step(engine, regular_expressions, r_url, r_json)
        if not build_step_failure_tuples:
            engine.logger.warn(
                'WARNING: No specific step failed for build "%d"\n' % build_number)

        return build_step_failure_tuples

    return circlefetch.get_json_or_fail(r, callback, "Build details fetch failed for build number: " + str(build_number))


def find_matches(engine, api_token):

    engine.logger.log("Populating matches...")

    unscanned_patterns_by_build = sorted(sqlread.get_unscanned_build_patterns(engine.conn).items(), reverse=True)
    patterns_by_id = sqlread.get_patterns(engine.conn)
    scan_id = sqlwrite.insert_scan_row(engine.conn)

    counter_wrapper = CounterWrapper()

    def search_log_partial(build_pattern_tuple):

        build_num, unscanned_pattern_ids = build_pattern_tuple

        build_step_failure_tuples = search_log(engine, api_token, patterns_by_id, unscanned_pattern_ids, build_num)

        line_count_info_string_parts = []
        for build_step_name, is_timeout, (line_count, matches) in build_step_failure_tuples:
            line_count_info_string_parts.append('"%s": %d' % (build_step_name, line_count))

        counter_wrapper.atomic_increment()

        line_counts_string = ";".join(line_count_info_string_parts)
        substitutions = (counter_wrapper.val, len(unscanned_patterns_by_build), build_num, line_counts_string)

        engine.logger.log("Processed %d/%d logs (build id: %d; linecounts: %s)..." % substitutions)

        return build_num, unscanned_pattern_ids, scan_id, build_step_failure_tuples

    executor = ThreadPoolExecutor(max_workers=MAX_NETWORK_THREADS)
    results = executor.map(search_log_partial, unscanned_patterns_by_build)

    sqlwrite.insert_matches(engine, results)


def run(engine, options):

    sqlwrite.scrub_tables(engine.conn)

    sqlwrite.populate_patterns(engine.conn)

    populate_builds(engine, options)
    find_matches(engine, options.token)


class Engine:
    def __init__(self, conn):
        self.logger = myutils.Logger()
        self.conn = conn
