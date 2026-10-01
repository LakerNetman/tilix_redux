/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.util.locale;

import core.stdc.locale;

import std.conv : to;
import std.string : toStringz;

/**
 * Runs dg with LC_NUMERIC set to "C" so numbers are formatted with a decimal
 * point regardless of the user's locale, i.e. when generating JSON, then
 * restores the previous locale even if dg throws.
 */
T withCNumericLocale(T)(scope T delegate() dg) {
    // setlocale with null only queries the locale, copy the result since
    // the returned string may be overwritten by later calls
    char* current = setlocale(LC_NUMERIC, null);
    string previous = (current is null) ? "C" : to!string(current);
    setlocale(LC_NUMERIC, "C");
    scope(exit) setlocale(LC_NUMERIC, toStringz(previous));
    return dg();
}

