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

unittest {
    import core.stdc.stdio : snprintf;
    import std.exception : assertThrown;
    import std.json : JSONValue;

    string numericLocale() {
        return to!string(setlocale(LC_NUMERIC, null));
    }

    string formatC(double value) {
        char[32] buffer;
        int length = snprintf(buffer.ptr, buffer.length, "%.1f", value);
        return buffer[0 .. length].idup;
    }

    string original = numericLocale();
    scope(exit) setlocale(LC_NUMERIC, toStringz(original));

    // The locale is C inside and restored afterwards
    assert(withCNumericLocale(() => numericLocale()) == "C");
    assert(numericLocale() == original);

    // Restored even when an exception is thrown
    assertThrown!Exception(withCNumericLocale(delegate int() { throw new Exception("test"); }));
    assert(numericLocale() == original);

    // With a locale that uses a decimal comma, if one is installed, numbers are
    // formatted with a point inside and the comma locale is restored afterwards
    foreach (candidate; ["de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8", "en_DK.UTF-8", "en_DK.utf8"]) {
        if (setlocale(LC_NUMERIC, toStringz(candidate)) is null) continue;
        if (formatC(0.5) != "0,5") continue;
        assert(withCNumericLocale(() => formatC(0.5)) == "0.5");
        assert(withCNumericLocale(() => JSONValue(0.5).toString()) == "0.5");
        assert(numericLocale() == candidate);
        assert(formatC(0.5) == "0,5");
        break;
    }
}
