/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.util.file;

import core.sys.posix.unistd : fsync, getpid;

import std.conv : to;
import std.exception : ErrnoException;
import std.file;
import std.path;
import std.stdio : File;

/**
 * Writes content to filename so that a crash, a full disk or any other error part
 * way through never leaves a truncated or partly written file.
 *
 * The content is written to a temporary file in the same directory, flushed to disk
 * and then renamed over the file, which replaces it in one step. The permissions of
 * an existing file are kept, its owner isn't since that needs root. If filename is a
 * symbolic link the file it points to is replaced, not the link.
 *
 * Replacing a file needs write permission on its directory. If the temporary file
 * can't be created there, the file is written in place instead, as before, so a file
 * that can be written in a directory that can't still saves, just not atomically.
 *
 * Throws: FileException or ErrnoException if the file can't be written. The original
 * file is left unchanged and the temporary file is removed.
 */
void writeFileAtomic(string filename, const(void)[] content) {
    string target = resolveSymlinks(filename);
    // Hidden and unique to this process so it never collides with another writer
    string temp = buildPath(dirName(target), "." ~ baseName(target) ~ "." ~ to!string(getpid()) ~ ".tmp");
    scope(failure) {
        try {
            if (exists(temp)) remove(temp);
        } catch (Exception e) {
            // Report the original error rather than this one
        }
    }
    File file;
    try {
        file = File(temp, "wb");
    } catch (Exception e) {
        // i.e. no write permission on the directory, write in place as before
        std.file.write(target, content);
        return;
    }
    file.rawWrite(content);
    file.flush();
    if (fsync(file.fileno) != 0) {
        throw new ErrnoException("Could not flush " ~ temp ~ " to disk");
    }
    file.close();
    if (exists(target)) {
        setAttributes(temp, getAttributes(target));
    }
    rename(temp, target);
}

private:

/**
 * Follows symbolic links to the file they point to, which need not exist yet
 */
string resolveSymlinks(string path) {
    // The same limit as the kernel, guards against a loop of links
    foreach (i; 0 .. 40) {
        try {
            if (!isSymlink(path)) return path;
        } catch (FileException e) {
            // Doesn't exist
            return path;
        }
        string link = readLink(path);
        path = isAbsolute(link) ? link : buildNormalizedPath(dirName(path), link);
    }
    throw new FileException(path, "Too many levels of symbolic links");
}

unittest {
    import core.sys.posix.unistd : geteuid;
    import std.algorithm : canFind, endsWith, filter, map;
    import std.conv : octal;
    import std.array : array;
    import std.exception : assertThrown;
    import std.process : thisProcessID;

    string dir = buildPath(tempDir(), "tilix-file-test-" ~ to!string(thisProcessID()));
    mkdirRecurse(dir);
    scope(exit) {
        setAttributes(dir, octal!"755");
        rmdirRecurse(dir);
    }

    // Files other than the given ones, i.e. a temporary file left behind
    string[] others(string[] expected...) {
        return dirEntries(dir, SpanMode.depth).map!(e => baseName(e.name)).filter!(n => !expected.canFind(n)).array;
    }

    // A new file, then replacing it
    string file = buildPath(dir, "session.json");
    writeFileAtomic(file, "first");
    assert(readText(file) == "first");
    writeFileAtomic(file, "second, longer content");
    assert(readText(file) == "second, longer content");
    writeFileAtomic(file, "");
    assert(readText(file) == "");
    ubyte[] binary = [0, 1, 2, 255];
    writeFileAtomic(file, binary);
    assert(cast(ubyte[]) read(file) == binary);
    assert(others("session.json").length == 0);

    // The file is replaced by a new one rather than overwritten in place, which is
    // what makes it atomic: another hard link to the old file still has the old content
    string hardLink = buildPath(dir, "hardlink.json");
    writeFileAtomic(file, "before");
    import core.sys.posix.unistd : makeHardLink = link;
    import std.string : toStringz;
    assert(makeHardLink(toStringz(file), toStringz(hardLink)) == 0);
    writeFileAtomic(file, "after");
    assert(readText(file) == "after");
    assert(readText(hardLink) == "before");
    remove(hardLink);

    // Permissions are kept
    setAttributes(file, octal!"600");
    writeFileAtomic(file, "private");
    assert((getAttributes(file) & octal!"777") == octal!"600");

    // Writing through a symbolic link replaces the file it points to, not the link,
    // including relative links into another directory
    mkdirRecurse(buildPath(dir, "dotfiles"));
    string actual = buildPath(dir, "dotfiles", "work.json");
    write(actual, "old");
    string link = buildPath(dir, "work.json");
    symlink(buildPath("dotfiles", "work.json"), link);
    writeFileAtomic(link, "new");
    assert(isSymlink(link));
    assert(readText(actual) == "new");
    // A link to a file that doesn't exist yet creates it
    string dangling = buildPath(dir, "later.json");
    symlink(buildPath(dir, "dotfiles", "later.json"), dangling);
    writeFileAtomic(dangling, "created");
    assert(isSymlink(dangling) && readText(buildPath(dir, "dotfiles", "later.json")) == "created");
    // A loop of links is an error rather than hanging
    symlink(buildPath(dir, "loop2"), buildPath(dir, "loop1"));
    symlink(buildPath(dir, "loop1"), buildPath(dir, "loop2"));
    assertThrown!FileException(writeFileAtomic(buildPath(dir, "loop1"), "x"));

    // A failure leaves no temporary file behind, i.e. replacing a directory
    string folder = buildPath(dir, "folder");
    mkdirRecurse(folder);
    assertThrown(writeFileAtomic(folder, "x"));
    assert(isDir(folder));
    assert(!others().canFind!(n => n.endsWith(".tmp")));

    // In a directory that can't be written to, a file that can be written is still
    // saved, in place, and one that can't be written is an error that leaves it unchanged.
    // Root can write anyway so this is skipped when running as root.
    if (geteuid() != 0) {
        string locked = buildPath(dir, "locked");
        mkdirRecurse(locked);
        string writable = buildPath(locked, "writable.json");
        string readOnly = buildPath(locked, "readonly.json");
        write(writable, "original");
        write(readOnly, "original");
        setAttributes(readOnly, octal!"444");
        setAttributes(locked, octal!"555");
        writeFileAtomic(writable, "replacement");
        assertThrown(writeFileAtomic(readOnly, "replacement"));
        setAttributes(locked, octal!"755");
        assert(readText(writable) == "replacement");
        assert(readText(readOnly) == "original");
        assert(others().filter!(n => n.endsWith(".tmp")).array.length == 0);
    }
}
