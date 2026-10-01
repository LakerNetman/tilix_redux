/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.util.path;

import std.array : appender;
import std.ascii : isAlphaNum;
import std.path;
import std.process;
import std.string;

/**
 * Resolves the path by converting tilde and environment
 * variables in the path.
 *
 * Variables are looked up with getenv and relative paths are made absolute
 * using cwd. When Tilix is already running, command line paths come from
 * another process so the caller must pass that process's environment and
 * working directory. By default the current process environment is used and
 * relative paths are left as is.
 */
string resolvePath(string path, string delegate(string) getenv = null, string cwd = null) {
    if (getenv is null) getenv = (string name) => environment.get(name);
    string result = expandVariables(expandTilde(path), getenv);
    if (cwd.length > 0 && isAbsolute(cwd) && !isAbsolute(result)) {
        result = absolutePath(result, cwd);
    }
    return result;
}

private:

/**
 * Replaces $NAME and ${NAME} with the value of the variable in a single pass,
 * so that $HOMEDIR is never treated as $HOME followed by DIR. Unknown
 * variables are left as is.
 */
string expandVariables(string path, string delegate(string) getenv) {
    auto result = appender!string();
    size_t start = 0;
    size_t i = 0;
    while (i < path.length) {
        if (path[i] == '$' && i + 1 < path.length) {
            size_t nameStart = i + 1;
            size_t nameEnd = nameStart;
            size_t next;
            if (path[nameStart] == '{') {
                ptrdiff_t close = path.indexOf('}', nameStart);
                if (close > 0) {
                    nameStart++;
                    nameEnd = close;
                    next = close + 1;
                }
            } else {
                while (nameEnd < path.length && (isAlphaNum(path[nameEnd]) || path[nameEnd] == '_')) nameEnd++;
                next = nameEnd;
            }
            if (nameEnd > nameStart) {
                string value = getenv(path[nameStart .. nameEnd]);
                if (value !is null) {
                    result.put(path[start .. i]);
                    result.put(value);
                    i = next;
                    start = i;
                    continue;
                }
            }
        }
        i++;
    }
    result.put(path[start .. $]);
    return result.data;
}

unittest {
    string[string] env = ["HOME": "/home/u", "HOMEDIR": "/srv/h", "X": "$HOME"];
    string delegate(string) getenv = (string name) => (name in env) ? env[name] : null;
    assert(resolvePath("$HOMEDIR/a", getenv) == "/srv/h/a");
    assert(resolvePath("${HOME}DIR/$X/$UNSET/${}", getenv) == "/home/uDIR/$HOME/$UNSET/${}");
    assert(resolvePath("sub/dir", getenv, "/work") == "/work/sub/dir");
    assert(resolvePath("/abs", getenv, "/work") == "/abs");
    assert(resolvePath("rel", getenv) == "rel");
}

