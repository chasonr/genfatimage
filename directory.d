// directory.d -- manage FAT file system directories
//
// Copyright © 2025 Ray Chason.
// 
// This file is part of genfatimage.
// 
// genfatimage is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation; either version 3, or (at your option) any later
// version.
// 
// genfatimage is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.
// 
// You should have received a copy of the GNU General Public License
// along with genfatimage; see the file LICENSE.  If not see
// <http://www.gnu.org/licenses/>.

import std.algorithm;
import std.array;
import std.datetime;
import std.file;
import std.format;
import std.path;
import std.stdio;
import std.string;
import std.utf;
import std.uni;

import unicode;
import pack;

class FATDirEntry {
public:
    string path;    // path to source file
    string name;    // name appearing on output volume
    uint attrs;
    uint firstCluster;
    uint fileSize;
    SysTime createdTime;
    SysTime modifiedTime;
    SysTime accessedTime;

    // For directories
    FATDirEntry[] dirEntries;
    ubyte[] dirText;

    // Build the on-disk representations of the directories, and set the
    // starting clusters of each entry
    void buildDirEntries(bool rootDir, string volumeLabel, ref uint cluster,
            uint parentCluster, uint clusterSize, uint fatSize)
    {
        // Reset dirText, so we can call this function more than once
        dirText.length = 0;

        if (rootDir) {
            if (fatSize != 32 || dirEntries.length == 0) {
                // Root directory on FAT12 or FAT16, or empty root directory on FAT32
                firstCluster = 0;
            } else {
                firstCluster = cluster;
            }
        } else {
            // "Empty" non-root directories still need at least one cluster, for the
            // "." and ".." entries
            if (attrs == Directory.Attrs.directory || fileSize != 0) {
                firstCluster = cluster;
            } else {
                firstCluster = 0;
            }
        }

        if (attrs == Directory.Attrs.directory) {
            // The root directory gets a volume label entry, if a volume
            // label is specified
            // Others get "." and ".." entries.
            if (rootDir) {
                if (!volumeLabel.empty) {
                    addDummyEntry(volumeLabel, Directory.Attrs.label, 0);
                }
            } else {
                addDummyEntry(".", Directory.Attrs.directory, firstCluster);
                addDummyEntry("..", Directory.Attrs.directory, parentCluster);
            }

            // List of existing short names, so we don't make duplicates
            bool[string] shortNames;
            foreach (ref FATDirEntry entry ; dirEntries) {
                string name = entry.name;
                if (isShortName(name)) {
                    shortNames[name.toUpper()] = true;
                }
            }

            // Add directory entries
            foreach (ref FATDirEntry entry ; dirEntries) {
                string sname;
                if (isShortName(entry.name)) {
                    sname = entry.name;
                } else {
                    // Build LFN records
                    sname = makeShortName(entry.name, shortNames);
                    auto csum = checksum(sname);
                    auto lname = toUTF16(entry.name);
                    if (lname.length > 255) {
                        throw new Exception(entry.name ~ ": Name is too long");
                    }
                    auto numRecs = (lname.length + CharsPerLFNRec - 1) / CharsPerLFNRec;
                    auto i = numRecs;
                    while (i != 0) {
                        ubyte sequence = cast(ubyte)(i | ((i == numRecs) ? 0x40 : 0x00));
                        --i;
                        auto start = i * CharsPerLFNRec;
                        auto end = min(start + CharsPerLFNRec, lname.length);
                        auto seg = lname[start..end];
                        addLFNRecord(sequence, seg, csum);
                    }
                }
                addDirRecord(entry, sname);
            }

            // We now know the length of the current directory.
            if (firstCluster != 0) { // i.e., not FAT12 or FAT16 root directory
                cluster += (dirText.length + clusterSize - 1) / clusterSize;
            }

            // Set first clusters and build subdirectories
            foreach (ref FATDirEntry entry ; dirEntries) {
                entry.buildDirEntries(false, "", cluster, rootDir ? 0 : firstCluster, clusterSize, fatSize);
                // First cluster
                ubyte[4] bytes;
                setNumber(bytes, entry.firstCluster);
                dirText[entry.dirEntry+26] = bytes[0];
                dirText[entry.dirEntry+27] = bytes[1];
                dirText[entry.dirEntry+20] = bytes[2];
                dirText[entry.dirEntry+21] = bytes[3];
            }
        } else {
            // Normal file
            cluster += (fileSize + clusterSize - 1) / clusterSize;
        }
    }

    // Return the number of directory entries
    ulong numDirEntries()
    {
        return dirText.length / BytesPerDirEntry;
    }

    // Write the file or directory to the volume and update the FAT
    void writeFile(ref uint[] fat, File volume, ulong rootDirOffset, ulong dataOffset,
            uint clusterSize)
    {
        if (firstCluster == 0) {
            // Either empty file or FAT12/FAT16 root directory
            // Non-root directories have at least one cluster for "." and ".."
            if (attrs == Directory.Attrs.directory) {
                // Assert that the root directory area is specified
                assert(rootDirOffset != 0);
                // and that it does not encroach into the data area
                assert(rootDirOffset + dirText.length <= dataOffset);

                volume.seek(rootDirOffset);
                volume.rawWrite(dirText);
            }
            // else empty file
        } else {
            // This is a normal cluster chain
            // Write the FAT entries
            uint size;
            if (attrs == Directory.Attrs.directory) {
                size = cast(uint)(dirText.length);
            } else {
                size = fileSize;
            }
            uint numClusters = (size + clusterSize - 1) / clusterSize;
            uint nextCluster = firstCluster + numClusters;
            if (fat.length < nextCluster) {
                fat.length = nextCluster;
            }
            foreach (uint i; firstCluster..(nextCluster-1)) {
                fat[i] = i + 1;
            }
            fat[nextCluster - 1] = 0xFFFFFFFF;
            // Write the file contents
            volume.seek(dataOffset + (firstCluster-2)*clusterSize);
            if (attrs == Directory.Attrs.directory) {
                volume.rawWrite(dirText);
            } else {
                ubyte[4096] buf;
                auto fp = File(path, "rb");
                while (true) {
                    auto res = fp.rawRead(buf);
                    if (res.length == 0) {
                        break;
                    }
                    volume.rawWrite(res);
                }
            }
        }

        foreach (entry; dirEntries) {
            entry.writeFile(fat, volume, rootDirOffset, dataOffset, clusterSize);
        }
    }

private:
    static const uint BytesPerDirEntry = 32;
    static const uint CharsPerLFNRec = 13;

    ulong dirEntry;

    struct DosTime {
        ubyte centiseconds;
        ushort dosTime;
        ushort dosDate;
    };

    // Add a volume label or a . or .. entry
    void addDummyEntry(string str, uint attrs, uint cluster)
    {
        auto start = dirText.length;
        dirText.length += BytesPerDirEntry;
        auto dirBytes = dirText[start..$];

        setString(dirBytes[0..11], str);
        setNumber(dirBytes[11..12], attrs);
        ubyte[4] bytes;
        setNumber(bytes, cluster);
        dirBytes[26] = bytes[0];
        dirBytes[27] = bytes[1];
        dirBytes[20] = bytes[2];
        dirBytes[21] = bytes[3];
    }

    // Add a short-name directory record
    void addDirRecord(FATDirEntry entry, string sname)
    {
        auto start = dirText.length;
        dirText.length += BytesPerDirEntry;
        auto dirBytes = dirText[start..$];

        entry.dirEntry = start;

        // Short name
        set83Name(dirBytes[0..11], sname);

        // Attributes
        dirBytes[11] = cast(ubyte)(entry.attrs);

        // Case flags
        dirBytes[12] = 0;
        foreach (uint i; 0..11) {
            if ('a' <= dirBytes[i] && dirBytes[i] <= 'z') {
                dirBytes[12] |= (i >= 8 ? 0x10 : 0x08);
                dirBytes[i] &= ~0x20;
            }
        }

        // Time stamps
        auto dtime = timeToDosTime(entry.createdTime);
        dirBytes[13] = dtime.centiseconds;
        setNumber(dirBytes[14..16], dtime.dosTime);
        setNumber(dirBytes[16..18], dtime.dosDate);
        dtime = timeToDosTime(entry.accessedTime);
        setNumber(dirBytes[18..20], dtime.dosDate);
        dtime = timeToDosTime(entry.modifiedTime);
        setNumber(dirBytes[22..24], dtime.dosTime);
        setNumber(dirBytes[24..26], dtime.dosDate);

        // File size
        if (entry.attrs == Directory.Attrs.directory) {
            setNumber(dirBytes[28..32], 0U);
        } else {
            setNumber(dirBytes[28..32], entry.fileSize);
        }
    }

    // Convert SysTime to DOSTime
    DosTime timeToDosTime(SysTime stime)
    {
        DosTime dtime;

        auto dosYear = stime.year - 1980;
        auto dosMonth = cast(uint)(stime.month);
        auto dosDay = stime.day;
        auto dosHour = stime.hour;
        auto dosMinute = stime.minute;
        auto dosSecond = stime.second;
        dtime.centiseconds = cast(ubyte)(stime.fracSecs.total!"msecs" / 10);
        if (dosYear < 0) {
            // Earliest valid time
            dosYear = 0;
            dosMonth = 1;
            dosDay = 1;
            dosHour = 0;
            dosMinute = 0;
            dosSecond = 0;
            dtime.centiseconds = 0;
        } else if (dosYear > 127) {
            // Latest valid time
            dosYear = 127;
            dosMonth = 12;
            dosDay = 31;
            dosHour = 23;
            dosMinute = 59;
            dosSecond = 59;
            dtime.centiseconds = 99;
        }

        dtime.centiseconds += (dosSecond & 1) * 100;
        dtime.dosTime = cast(ushort)((dosHour << 11) | (dosMinute << 5) | (dosSecond >> 1));
        dtime.dosDate = cast(ushort)((dosYear << 9) | (dosMonth << 5) | dosDay);

        return dtime;
    }

    // Add a long-name directory record
    void addLFNRecord(ubyte sequence, wstring seg, ubyte csum)
    {
        auto start = dirText.length;
        dirText.length += BytesPerDirEntry;
        auto dirBytes = dirText[start..$];

        // Where to put the file name characters
        static const ubyte[CharsPerLFNRec] charPos = [
             1,  3,  5,  7,  9,
            14, 16, 18, 20, 22, 24,
            28, 30
        ];

        // Place the file name characters
        foreach (uint j; 0..CharsPerLFNRec) {
            int pos = charPos[j];
            if (j >= seg.length) {
                setNumber(dirBytes[pos..(pos+2)], 0U); 
            } else {
                setNumber(dirBytes[pos..(pos+2)], seg[j]); 
            }
        }

        // Place the other things
        dirBytes[ 0] = sequence;
        dirBytes[11] = Directory.Attrs.lfn;
        dirBytes[12] = 0;
        dirBytes[13] = csum;
        dirBytes[26] = 0;
        dirBytes[27] = 0;
    }

    // Checksum used in long file name records to determine whether the short name
    // still matches
    static ubyte
    checksum(string shortName)
    {
        ubyte[11] name2;

        set83Name(name2, shortName);

        // Wikipedia, at
        // https://en.wikipedia.org/w/index.php?title=Design_of_the_FAT_file_system&oldid=1278385983

        ubyte sum = 0;

        foreach (ref ubyte b; name2) {
            sum = cast(ubyte)(((sum & 1) << 7) + (sum >> 1) + b);
        }

        return sum;
    }

    // Set an 8.3 name into a byte array
    // Leave lowercase letters as they are; they will be fixed later
    static void
    set83Name(ref ubyte[11] buf, string name)
    {
        auto dot = indexOf(name, '.');
        if (dot >= 0) {
            setString(buf[0..8], name[0..dot]);
            setString(buf[8..11], name[dot+1..$]);
        } else {
            setString(buf[0..8], name);
            buf[8..11] = ' ';
        }
    }

    // Return true if the name is usable as a short name
    static bool
    isShortName(string name)
    {
        auto parts = name.split('.');

        if (parts.length == 1) {
            // No extension; should be one to eight characters and not mixed case
            return isOKName(parts[0], 8);
        } else if (parts.length == 2) {
            // Extension is present; should have one to eight characters before the
            // period and one to three characters after
            return isOKName(parts[0], 8)
                && isOKName(parts[1], 3);
        } else {
            return false;
        }
    }

    // Make a short name for the given long name, that does not match existing
    // short names; add the new short name to the list
    static string
    makeShortName(string longName, ref bool[string] shortNames)
    {
        char[] part1a, part2a;
        bool dot = false;

        // Form the untagged first and second parts of the short name
        foreach (char b; longName) {
            if (b == '.') {
                dot = true;
                if (part2a.empty) {
                    ++part2a.length;
                    part2a[$-1] = '.';
                }
            } else {
                auto b2 = b;
                if (!isAllowedChar(b2)) {
                    b2 = '_';
                } else if ('a' <= b2 && b2 <= 'z') {
                    b2 &= ~0x20;
                }
                if (dot) {
                    if (part2a.length >= 4) {
                        break;
                    }
                    ++part2a.length;
                    part2a[$-1] = b2;
                } else {
                    if (part1a.length < 8) {
                        ++part1a.length;
                        part1a[$-1] = b2;
                    }
                }
            }
        }

        auto part1 = part1a.idup;
        auto part2 = part2a.idup;

        // Add a tag to part1
        foreach (uint i; 1..9999999) {
            // Build a candidate short name
            auto tag = format("~%u", i);
            string sname;
            if (part1.length + tag.length > 8) {
                sname = part1[0..(8-tag.length)] ~ tag ~ part2;
            } else {
                sname = part1 ~ tag ~ part2;
            }

            // Look for this name among the existing short names
            if (!(sname in shortNames)) {
                // No existing file has this short name; use it
                shortNames[sname] = true;
                return sname;
            }
        }

        // We should never get here
        throw new Exception(longName ~ ": Could not create a unique short name");
    }

    static bool
    isOKName(string name, uint maxLen)
    {
        // Check the size
        if (name.length < 1) {
            return false;
        }
        if (name.length > maxLen) {
            return false;
        }

        bool lower = false;
        bool upper = false;

        foreach (byte ch; name) {
            if ('A' <= ch && ch <= 'Z') {
                upper = true;
            } else if ('a' <= ch && ch <= 'z') {
                lower = true;
            } else if (!isAllowedChar(ch)) {
                return false;
            }
        }

        // Check for mixed case
        return !(upper && lower);
    }

    static bool
    isAllowedChar(byte ch)
    {
        static const uint[] allowedMap = [
            0x00000000,     // 0x00 - 0x1F
            0x03FF23FA,     // 0x20 - 0x3F; 0-9 ! # $ % & ' ( ) -; not space " * + , . / : ; < = > ?
            0xC7FFFFFF,     // 0x40 - 0x5F; A-Z @ ^ _; not [ \ ]
            0x6FFFFFFF,     // 0x60 - 0x7F; a-z ` { } ~; not |
            0x00000000,     // 0x80 - 0x9F
            0x00000000,     // 0xA0 - 0xBF
            0x00000000,     // 0xC0 - 0xDF
            0x00000000      // 0xE0 - 0xFF
        ];

        return (allowedMap[cast(ubyte)(ch) >> 5] >> (ch & 0x1F)) & 1;
    }
};

class Directory {
public:
    enum Attrs {
        readOnly  = 0x01,
        hidden    = 0x02,
        system    = 0x04,
        label     = 0x08,
        directory = 0x10,
        archive   = 0x20,

        // If attrs is equal to this, the entry is a Long File Name record
        lfn       = 0x0F
    };

    this()
    {
        rootDir = new FATDirEntry;
        rootDir.attrs = Attrs.directory;
    }

    // Add a file to the file system
    void addFile(string path, string pathOnDisk, uint attrs)
    {
        if (pathOnDisk.empty) {
            pathOnDisk = baseName(path);
        }

        // Add directories as needed
        auto path2 = split(pathOnDisk, '/');
        FATDirEntry[] *dir = &rootDir.dirEntries;
        uint i = 0;
        while (i + 1 < path2.length) {
            auto dname = path2[i];
            auto entry = addEntry(*dir, dname, Attrs.directory);
            dir = &entry.dirEntries;
            ++i;
        }

        // Get information on the object being added
        if (isFile(path)) {
            // Limit attrs to readonly, hidden, system and archive
            attrs &= Attrs.readOnly
                   | Attrs.hidden
                   | Attrs.system
                   | Attrs.archive;
        } else if (isDir(path)) {
            // Ignore attrs and make the entry a directory
            attrs = Attrs.directory;
        } else {
            // We can't add this
            throw new Exception(path ~ ": Can't add a special file");
        }

        // Add to the directory
        auto entry = addEntry(*dir, path2[$-1], attrs);
        entry.path = path;
        if (isFile(path)) {
            auto size = getSize(path);
            if (size > 0xFFFFFFFF) {
                throw new Exception(path ~ ": File is too large");
            }
            entry.fileSize = cast(uint)(size);
        }
        version (Windows) {
            getTimesWin(path, entry.createdTime, entry.accessedTime,
                        entry.modifiedTime);
        } else {
            getTimes(path, entry.accessedTime, entry.modifiedTime);
            entry.createdTime = entry.modifiedTime;
        }
    }

    // Return the number of entries in the root directory
    ulong numRootDirEntries()
    {
        return rootDir.numDirEntries();
    }

    // Return the first cluster of the root directory
    uint rootDirStart()
    {
        return rootDir.firstCluster;
    }

    // Build the on-disk representations of the directories
    // Return the number of clusters
    uint buildDirectories(string volumeLabel, uint clusterSize, uint fatSize)
    {
        uint cluster = 2;
        rootDir.buildDirEntries(true, volumeLabel, cluster, 0, clusterSize, fatSize);
        return cluster - 2;
    }

    // Write files and directories to the volume
    // Return the FAT represented as an array of uints
    uint[] writeVolume(ref File volume, ulong rootDirOffset, ulong dataOffset,
            uint clusterSize)
    {
        uint[] fat = [ 0xFFFFFFFF, 0xFFFFFFFF ];

        rootDir.writeFile(fat, volume, rootDirOffset, dataOffset, clusterSize);
        return fat;
    }

private:
    FATDirEntry rootDir;

    // Add an entry to a FATDirEntry array
    static FATDirEntry addEntry(ref FATDirEntry[] entries, string name, uint attrs)
    {
        // Is the name already there?
        uint i;
        for (i = 0; i < entries.length; ++i) {
            if (caseMatch(entries[i].name, name)) {
                break;
            }
        }

        if (i < entries.length) {
            // The name was found.
            // If adding a directory, and the existing name is a directory,
            // let it be, and return the existing entry
            if (attrs == Attrs.directory
            &&  entries[i].attrs == Attrs.directory) {
                return entries[i];
            }

            // Otherwise this is an error
            throw new Exception("Duplicate name: " ~ name);
        }

        // Create a new entry
        // Because this entry need not correspond to an actual entity on the
        // file system, set the times to current time
        ++entries.length;
        entries[i] = new FATDirEntry;
        entries[i].name = name;
        entries[i].attrs = attrs;
        auto now = Clock.currTime();
        entries[i].createdTime = now;
        entries[i].modifiedTime = now;
        entries[i].accessedTime = now;

        return entries[i];
    }
};
