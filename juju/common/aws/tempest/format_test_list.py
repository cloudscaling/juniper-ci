#    Copyright 2014 Cloudscaling Group, Inc
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import os
import sys


def read_items(configs_dir, file_name, items):
    files = [file_name]
    while len(files) > 0:
        file_name = files.pop()
        file_path = os.path.join(configs_dir, file_name)
        try:
            f = open(file_path)
            result = f.read()
            f.close()
            for item in result.splitlines():
                if not item or item[0] == '#':
                    continue
                if item[0] == '!':
                    files.append(item[1:])
                    continue

                items.add(item)
        except Exception:
            pass


def main():
    # program.sh CONFIG_DIR CONFIG_FILE FILE_WITH_TEST_LIST
    if len(sys.argv) < 4:
        print("args: CONFIG_DIR CONFIG_FILE FILE_WITH_TEST_LIST")
        sys.exit(1)

    configs_dir = sys.argv[1]
    config_name = sys.argv[2]
    excludes = set()
    read_items(configs_dir, config_name, excludes)

    tests = set()
    read_items(".", sys.argv[3], tests)
    for test in tests:
        for exclude in excludes:
            if exclude in test:
                break
        else:
            print(test)

if __name__ == '__main__':
    main()
