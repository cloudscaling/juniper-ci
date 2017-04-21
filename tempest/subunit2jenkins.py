#!/usr/bin/python
# Copyright 2014
# The Cloudscaling Group, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Filter a subunit stream to get xml, compatible with Jenkins JUnit plugin"""

import extras
import optparse
import sys

import junitxml
import subunit.filters
import testtools


#TODO(ft): Remove using junitxml.
#Almost all of its main features have been implemented here,
#so the value of using this external module requires a separate installation
#is not high.
#Useful features of junitxml used now are:
# - implementation of rest testtools.TestResult interface;
# - _escape_attr, _escape_content;
# - time duration calculation.
class JenkinsXmlResult(junitxml.JUnitXmlResult):

    def __init__(self, suite_name, stream):
        super(JenkinsXmlResult, self).__init__(stream)
        self.suite_name = suite_name if suite_name is not None else ''

    #NOTE(ft): overwritten due to 'name' attribute setting
    def stopTestRun(self):
        duration = self._duration(self._run_start)
        self._stream.write(
            '<testsuite name="%(name)s" tests="%(tests)d" '
            'failures="%(failures)d" errors="%(errors)d" '
            'time="%(duration)0.3f">\n' %
            {'name': junitxml._escape_attr(self.suite_name),
             'tests': self.testsRun,
             'failures': (len(self.failures) +
                          len(getattr(self, "unexpectedSuccesses", ()))),
             'errors': len(self.errors),
             'duration': duration, })
        self._stream.write(''.join(self._results))
        self._stream.write('</testsuite>\n')

    #NOTE(ft): overwritten due to 'message' attribute setting
    def addSkip(self, test, reason):
        self._test_case_string(test)
        self._results.append('>\n')
        self._results.append('<skipped message="%s"/>\n</testcase>\n' %
                             junitxml._escape_attr(reason))
        self.skipped.append(test.id())

    #NOTE(ft): overwritten due to 'message' attribute and
    #'standard-out' tag setting
    def addFailure(self, test, details):
        #NOTE(ft): skip specific testr generated failure
        if test.id() == 'process-returncode':
            self.testsRun -= 1
            return
        self._addException('failure', test, details)
        self.failures.append(test.id())

    #NOTE(ft): overwritten due to 'message' attribute and
    #'standard-out' tag setting
    def addError(self, test, details):
        self._addException('error', test, details)
        self.errors.append(test.id())

    #NOTE(ft): overwritten due to 'setupClass' case
    def _test_case_string(self, test):
        duration = self._duration(self._test_start)
        test_id = test.id()
        class_name, test_name = '', test_id
        if test_id.endswith(')'):
            #NOTE(ft): for 'setupClass (<class_name>)' case
            left_par = test_id.find('(')
            if left_par >= 0:
                class_name = test_id[left_par + 1:-1]
                test_name = test_id[:left_par].strip()
        else:
            #NOTE(ft): for '<class_name>.<test_name>' case
            last_dot = test_id.rfind('.')
            if last_dot >= 0:
                class_name = test_id[:last_dot]
                test_name = test_id[last_dot + 1:]
        self._results.append(
            '<testcase classname="%(class)s" name="%(test)s" '
            'time="%(duration)0.3f"' %
            {'class': junitxml._escape_attr(class_name),
             'test': junitxml._escape_attr(test_name),
             'duration': duration})

    def _addException(self, case, test, details):
        self._test_case_string(test)
        self._results.append('>\n')
        self._addTraceback(case, details.get('traceback'))
        self._addDetails(details, ('traceback', ))
        self._results.append('</testcase>\n')

    def _addTraceback(self, case, traceback):
        if traceback and traceback.content_type.type == 'text':
            traceback = traceback.as_text()
            message = self._getExceptionMessage(traceback)
        elif traceback:
            traceback = str(traceback)
            message = ''
        else:
            traceback = message = ''
        self._results.append(
            '<%(case)s message="%(message)s">%(traceback)s</%(case)s>\n' %
            {'case': case,
             'message': junitxml._escape_attr(message),
             'traceback': junitxml._escape_content(traceback), })

    def _getExceptionMessage(self, traceback_text):
        trace_lines = traceback_text.splitlines()
        for line_no in range(1, len(trace_lines), 2):
            if not trace_lines[line_no].startswith('  File '):
                break
        else:
            return ''
        return '\n'.join(trace_lines[line_no:])

    def _addDetails(self, details, skips):
        system_out = []
        for key, content in sorted(details.iteritems()):
            if (key in skips or
                    content.content_type.type != 'text'):
                continue
            text = content.as_text()
            if not text:
                continue
            system_out.append('\n%s\n'
                              '------------------------\n' % key)
            system_out.append(text)
            if text[-1] != '\n':
                system_out.append('\n')
            system_out.append('========================\n')
        if system_out:
            self._results.append('<system-out>%s</system-out>\n' %
                           junitxml._escape_content(''.join(system_out)))


def parse_options():
    parser = optparse.OptionParser(description=__doc__)
    parser.add_option(
        '-i', '--input-from',
        help='Receive the input from this path rather than stdin.')
    parser.add_option(
        '-o', '--output-to',
        help='Send the output to this path rather than stdout.')
    parser.add_option(
        '-s', '--suite',
        help='Test suite name to use in the output.')
    (options, _args) = parser.parse_args()
    return options


options = parse_options()
if options.input_from:
    input_stream = open(options.input_from, 'r')
else:
    input_stream = sys.stdin
passthrough, forward = False, False

result = subunit.filters.filter_by_result(
    lambda output: testtools.StreamToExtendedDecorator(
             JenkinsXmlResult(options.suite, output)),
    options.output_to, passthrough, forward, protocol_version=2,
    input_stream=input_stream)

if options.input_from:
    input_stream.close()
if not extras.safe_hasattr(result, 'wasSuccessful'):
    result = result.decorated
if result.wasSuccessful():
    sys.exit(0)
else:
    sys.exit(1)

