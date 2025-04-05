// genfatimage.d -- generate a FAT file system
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
import std.conv;
import std.datetime;
import std.file;
import std.format;
import std.path;
import std.range;
import std.regex;
import std.stdio;
import std.traits;
import core.stdc.stdlib;

import directory;
import pack;

const uint MaxFAT12Clusters = 0xFF4;
const uint MaxFAT16Clusters = 0xFFF4;
const uint MaxFAT32Clusters = 0xFFFFFF4;

struct FSOptions {
    // Output file
    string output;

    // Enable extra output
    bool verbose;

    // Preset volume formats
    bool fd360, fd720, fd1200, fd1440, fd2880;

    // Basic volume parameters
    ulong volumeSize;
    ulong freeSpace;
    uint clusterSize;
    ushort rootDirSize;
    bool fat12, fat16, fat32;
    bool partitioned;
    string label;
    string bootRecord;

    // Fine details
    string oemName;
    string serial;
    ushort sectorsPerTrack;
    ushort numHeads;
    string mediaDesc;

    // Advanced options
    ushort sectorSize;
    ushort reservedSectors;
    ubyte numFATs;
};

// Print an error message and exit
void
error(string msg)
{
    stderr.writeln(msg);
    exit(EXIT_FAILURE);
}

// Return true if a number is a power of two
bool
powerOfTwo(inttype)(inttype arg)
if (isIntegral!inttype)
{
    if (arg > 0) {
        while (!(arg & 1)) {
            arg >>= 1;
        }
    }
    return arg == 1;
}

// Convert option to numeric type with meaningful error message
void
convertNumeric(numtype)(string option, string value, ref numtype arg)
if (isUnsigned!numtype)
{
    try {
        auto match = matchFirst(value, r"^[0-9]+$");
        if (match.empty) {
            error(format("Option --%s requires a numeric value (not \"%s\")\n",
                    option, value));
        }
        arg = to!numtype(value);
    }
    catch (ConvException exc) {
        error(format("Option --%s: %s overflows", option, value));
    }
}

// Convert option to numeric type with meaningful error message
// Allow K, M, G suffix
void
convertSize(numtype)(string option, string value, ref numtype arg)
if (isUnsigned!numtype)
{
    try {
        auto match = matchFirst(value, r"^([0-9]+)([KMGkmg]?)$");
        if (match.empty) {
            error(format("Option --%s requires a numeric value, possibly with a K, M or G suffix (not \"%s\")\n",
                    option, value));
        }
        arg = to!numtype(match[1]);
        uint scale = 0;
        // Accept any K, M or G suffix
        if (match[2] != "") {
            switch (match[2][0]) {
            case 'k':
            case 'K':
                scale = 10;
                break;

            case 'm':
            case 'M':
                scale = 20;
                break;

            case 'g':
            case 'G':
                scale = 30;
                break;

            default:
                assert(0);
            }
        }
        numtype scaledArg = cast(numtype)(cast(ulong)(arg) << scale);
        // Check for overflow
        numtype arg2 = cast(numtype)(cast(ulong)(scaledArg) >> scale);
        if (arg2 != arg) {
            error(format("Option --%s: %s overflows", option, value));
        }
        arg = scaledArg;
    }
    catch (ConvException exc) {
        error(format("Option --%s: %s overflows", option, value));
    }
}

FSOptions
getOptions(ref string[] args)
{
    import std.getopt;

    FSOptions options;

    try {
        auto helpInfo = getopt(
            args,
            "o|output", "Set the output file name", &options.output,
            "v|verbose", "Enable extra output" ~ "\n\n" ~ "Preset image formats:\n", &options.verbose,

            "360",  "Generate a 360KB floppy image", &options.fd360,
            "720",  "Generate a 720KB floppy image", &options.fd720,
            "1200", "Generate a 1.2MB floppy image", &options.fd1200,
            "1440", "Generate a 1.44MB floppy image", &options.fd1440,
            "2880", "Generate a 2.88MB floppy image" ~ "\n\n" ~ "Basic volume parameters:" ~ "\n", &options.fd2880,

            "volume-size", "(numeric) Total size of volume",
                    delegate void(string option, string value) {
                        convertSize(option, value, options.volumeSize);
                    },
            "free-space", "(numeric) Minimum free space remaining on volume",
                    delegate void(string option, string value) {
                        convertSize(option, value, options.freeSpace);
                    },
            "cluster-size", "(numeric) Size of a cluster",
                    delegate void(string option, string value) {
                        convertSize(option, value, options.clusterSize);
                    },
            "rootdir", "(numeric) Number of root directory entries",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.rootDirSize);
                    },
            "fat12", "Generate a FAT12 volume", &options.fat12,
            "fat16", "Generate a FAT16 volume", &options.fat16,
            "fat32", "Generate a FAT32 volume", &options.fat32,
            "partitioned", "Image has a partition table", &options.partitioned,
            "label", "(string) Set the volume label", &options.label,
            "bootrec", "(string) File providing the boot record" ~ "\n\n" ~ "Fine details:" ~ "\n", &options.bootRecord,

            "oemname", "(string) OEM name", &options.oemName,
            "serial", "(hex-number) Volume serial number", &options.serial,
            "sectors-per-track", "(numeric) Sectors per track",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.sectorsPerTrack);
                    },
            "heads", "(numeric) Number of heads",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.numHeads);
                    },
            "media-desc", "(hex-number) Media descriptor" ~ "\n\n" ~ "Advanced options:" ~ "\n", &options.mediaDesc,

            "sector-size", "(numeric) Sector size",
                    delegate void(string option, string value) {
                        convertSize(option, value, options.sectorSize);
                    },
            "reserved-sectors", "(numeric) Number of reserved sectors",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.reservedSectors);
                    },
            "fats", "(numeric) Number of file allocation tables" ~ "\n",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.numFATs);
                    },
        );
        if (helpInfo.helpWanted) {
            writef("Usage: %s [options] <pathname> ...\n\n", args[0]);
            defaultGetoptPrinter("Options for this program follow.\n", helpInfo.options);
            exit(EXIT_FAILURE);
        }
    }
    catch (ConvException exc) {
        error(exc.msg);
    }
    catch (GetOptException exc) {
        error(exc.msg);
    }

    // Validate the given options:

    // Only one preset may be set
    uint presets = cast(uint)(options.fd360)
                 + cast(uint)(options.fd720)
                 + cast(uint)(options.fd1200)
                 + cast(uint)(options.fd1440)
                 + cast(uint)(options.fd2880);
    if (presets > 1) {
        error("Can set at most one of --360, --720, --1200, --1440 or --2880");
    }

    // Look for conflicts between presets and other options
    if (presets == 1) {
        // These conflict with the presets

        if (options.volumeSize != 0) {
            error("Cannot use preset option and also --volume-size");
        }
        if (options.clusterSize != 0) {
            error("Cannot use preset option and also --cluster-size");
        }
        if (options.rootDirSize != 0) {
            error("Cannot use preset option and also --rootdir");
        }
        if (options.fat16) {
            error("Cannot use preset option and also --fat16");
        }
        if (options.fat32) {
            error("Cannot use preset option and also --fat32");
        }
        if (options.partitioned) {
            error("Cannot use preset option and also --partitioned");
        }
        if (options.sectorsPerTrack != 0) {
            error("Cannot use preset option and also --sectors-per-track");
        }
        if (options.numHeads != 0) {
            error("Cannot use preset option and also --heads");
        }
        if (options.mediaDesc != "") {
            error("Cannot use preset option and also --media-desc");
        }
        if (options.sectorSize != 0) {
            error("Cannot use preset option and also --sector-size");
        }
        if (options.reservedSectors != 0) {
            error("Cannot use preset option and also --reserved-sectors");
        }
        if (options.numFATs != 0) {
            error("Cannot use preset option and also --fats");
        }

        // These are the dimensions of each preset

        options.fat12 = true;
        options.sectorSize = 512;
        options.reservedSectors = 1;
        options.numFATs = 2;

        if (options.fd360) {
            options.volumeSize = 360*1024;
            options.clusterSize = 1024;
            options.rootDirSize = 112;
            options.sectorsPerTrack = 9;
            options.numHeads = 2;
            options.mediaDesc = "FD";
            options.reservedSectors = 1;
        }
        if (options.fd720) {
            options.volumeSize = 720*1024;
            options.clusterSize = 1024;
            options.rootDirSize = 112;
            options.sectorsPerTrack = 9;
            options.numHeads = 2;
            options.mediaDesc = "F9";
            options.reservedSectors = 1;
        }
        if (options.fd1200) {
            options.volumeSize = 1200*1024;
            options.clusterSize = 512;
            options.rootDirSize = 112;
            options.sectorsPerTrack = 15;
            options.numHeads = 2;
            options.mediaDesc = "F9";
            options.reservedSectors = 1;
        }
        if (options.fd1440) {
            options.volumeSize = 1440*1024;
            options.clusterSize = 512;
            options.rootDirSize = 224;
            options.sectorsPerTrack = 18;
            options.numHeads = 2;
            options.mediaDesc = "F0";
            options.reservedSectors = 1;
        }
        if (options.fd2880) {
            options.volumeSize = 2880*1024;
            options.clusterSize = 1024;
            options.rootDirSize = 224;
            options.sectorsPerTrack = 36;
            options.numHeads = 2;
            options.mediaDesc = "F0";
            options.reservedSectors = 1;
        }

        // freeSpace, label, bootRecord, oemName and serial may be set without
        // conflict
    }

    // Check validity of other options

    if (options.sectorSize == 0) {
        options.sectorSize = 512;
    }
    if (options.sectorSize < 512 && options.fat32) {
        error("FAT32 requires sector size of at least 512");
    }
    if (options.sectorSize < 128) {
        error("--sector-size must be at least 128");
    }
    if (options.sectorSize > 32768) {
        error("--sector-size cannot exceed 32768");
    }
    if (!powerOfTwo(options.sectorSize)) {
        error("--sector-size must be a power of two");
    }

    if (options.clusterSize != 0) {
        if (options.clusterSize > options.sectorSize * 128) {
            error("--cluster-size cannot exceed 128 times the sector size");
        }
        if (options.clusterSize % options.sectorSize != 0
        ||  !powerOfTwo(options.clusterSize / options.sectorSize)) {
            error("--cluster-size must be a power of two times the sector size");
        }
    }

    if (cast(uint)(options.fat12) + cast(uint)(options.fat16) + cast(uint)(options.fat32) > 1) {
        error("Can specify at most one of --fat12, --fat16 or --fat32");
    }

    if (options.serial != "") {
        auto match = matchFirst(options.serial, r"^[0-9A-Fa-f]{1,4}-[0-9A-Fa-f]{1,4}$");
        if (match.empty) {
            error("--serial uses hex digits in the form 12AB-34CD");
        }
    }

    if (options.mediaDesc == "") {
        options.mediaDesc = options.partitioned ? "F8" : "F0";
    } else {
        auto match = matchFirst(options.mediaDesc, r"^[0-9A-Fa-f]{1,2}$");
        if (match.empty) {
            error("--media-desc must have one or two hex digits");
        }
    }

    if (args.length <= 1 && options.volumeSize == 0 && options.freeSpace == 0) {
        error("Must specify either --volume-size or --free-space, or at least one file");
    }

    // Set default values for some items

    if (options.reservedSectors == 0) {
        options.reservedSectors = 1;
    }

    if (options.numFATs == 0) {
        options.numFATs = 2;
    }

    if (options.sectorsPerTrack == 0) {
        options.sectorsPerTrack = 63;
    }

    if (options.numHeads == 0) {
        options.numHeads = 255;
    }

    return options;
}

// Return the number of sectors needed for one FAT
ulong
numFATSectors(ulong numClusters, uint fatSize, uint sectorSize)
{
    ulong fatBits = (numClusters+2) * fatSize;
    uint sectorBits = sectorSize * 8;
    ulong fatSectors = (fatBits + sectorBits - 1) / sectorBits;
    return fatSectors;
}

// Return the number of sectors needed for the root directory
ulong
numRootDirSectors(ulong numEntries, uint fatSize, uint sectorSize)
{
    if (fatSize == 32) {
        return 0;
    } else {
        ulong dirBytes = numEntries * 32;
        return (dirBytes + sectorSize - 1) / sectorSize;
    }
}

// Parse the serial number, or generate one
uint
serialNum(string snum)
{
    if (snum.empty) {
        return cast(uint)(Clock.currTime().toUnixTime);
    } else {
        auto match = matchFirst(snum, r"^([0-9A-Fa-f]+)-([0-9A-Fa-f]+)$");
        assert(!match.empty);
        auto left = to!uint(match[1], 16);
        auto right = to!uint(match[2], 16);
        return (left << 16) | right;
    }
}

// Add a directory tree to the volume
void
addDirTree(ref Directory dir, string path, bool verbose)
{
    ulong pathLen = 0;
    foreach (string s; pathSplitter(path)) {
        if (!s.empty) {
            ++pathLen;
        }
    }

    foreach (DirEntry ent; dirEntries(path, SpanMode.depth)) {
        auto splitName = pathSplitter(ent.name);
        string[] splitName2;

        ulong i = 0;
        foreach (string s; splitName) {
            if (i >= pathLen) {
                ++splitName2.length;
                splitName2[$-1] = s;
            }
            ++i;
        }
        auto name2 = splitName2.join("/");
        if (verbose) {
            writef("%s => %s\n", ent.name, name2);
        }
        dir.addFile(ent.name, name2, Directory.Attrs.archive);
    }
}

int
main(string[] args)
{
    FSOptions options = getOptions(args);

    auto dir = new Directory();

    foreach (string path; args[1..$]) {
        if (isDir(path)) {
            addDirTree(dir, path, options.verbose);
        } else {
            auto name2 = baseName(path);
            if (options.verbose) {
                writef("%s => %s\n", path, name2);
            }
            dir.addFile(path, name2, Directory.Attrs.archive);
        }
    }

    // Initially use FAT12 unless a different size is requested
    uint fatSize;
    if (options.fat16) {
        fatSize = 16;
    } else if (options.fat32) {
        fatSize = 32;
    } else {
        fatSize = 12;
    }

    // Cluster size is sector size unless a different size is requested
    uint clusterSize = max(options.sectorSize, options.clusterSize);

    // Hidden sectors is 0 unless a partition table is requested
    auto hiddenSectors = options.partitioned
                       ? max(options.sectorsPerTrack, 1)
                       : 0;

    // Number of sectors in the volume, if specified
    auto sectorsInVolume = (options.volumeSize + options.sectorSize - 1) / options.sectorSize;

    ulong numClusters;
    ulong numDirEntries;
    uint sectorsPerCluster;

    uint bootSector;
    uint reservedSectors;
    uint firstFATSector;
    ulong fatSectors;
    ulong rootDirSector;
    ulong firstDataSector;
    ulong endOfVolume;

    while (true) {
        // Build the arrangement of directories and files
        numClusters = dir.buildDirectories(options.label, clusterSize, fatSize);

        // Get number of sectors per cluster
        sectorsPerCluster = clusterSize / options.sectorSize;

        // Get root directory size
        numDirEntries = dir.numRootDirEntries();
        if (numDirEntries < options.rootDirSize && fatSize != 32) {
            numDirEntries = options.rootDirSize;
        }

        // Reserved sectors include the boot record, and for FAT32, some other areas
        reservedSectors = max(options.reservedSectors, (fatSize == 32) ? 32 : 1);

        // Account for requested free space
        numClusters += (options.freeSpace + clusterSize - 1) / clusterSize;

        // Determine the layout
        bootSector = hiddenSectors;
        firstFATSector = bootSector + reservedSectors;
        fatSectors = numFATSectors(numClusters, fatSize, options.sectorSize);
        rootDirSector = firstFATSector + fatSectors * options.numFATs;
        firstDataSector = rootDirSector + numRootDirSectors(numDirEntries, fatSize, options.sectorSize);
        endOfVolume = firstDataSector + numClusters * sectorsPerCluster;

        // If the volume size is set, extend to the configured size
        if (sectorsInVolume != 0) {
            if (endOfVolume > sectorsInVolume) {
                error("Volume is larger than the requested size");
            }

            auto extraSectors = sectorsInVolume - endOfVolume;
            auto extraClusters = extraSectors / sectorsPerCluster;
            numClusters += extraClusters;

            // Adding more clusters might enlarge the FATs and exceed the
            // configured volume size; back off if that happens
            while (extraClusters != 0) {
                fatSectors = numFATSectors(numClusters, fatSize, options.sectorSize);
                rootDirSector = firstFATSector + fatSectors * options.numFATs;
                firstDataSector = rootDirSector + numRootDirSectors(numDirEntries, fatSize, options.sectorSize);
                endOfVolume = firstDataSector + numClusters * sectorsPerCluster;
                if (endOfVolume <= sectorsInVolume) {
                    break;
                }
                --extraClusters;
                --numClusters;
            }
        }

        // Determine the FAT and cluster size needed for this cluster count
        uint newClusterSize = clusterSize;
        uint newFATSize = fatSize;
        if (numClusters > MaxFAT32Clusters) {
            // More clusters than even FAT32 can allow
            // Need a new cluster size
            newClusterSize *= 2;
        } else if (numClusters > MaxFAT16Clusters) {
            // FAT32 can handle the cluster count; but don't go to FAT32 if
            // the sector size is less than 512
            if (options.fat12 || options.fat16 || options.sectorSize < 512) {
                // Requested FAT12 or FAT16; bump the cluster size
                newClusterSize *= 2;
            } else {
                newFATSize = 32;
            }
        } else if (numClusters > MaxFAT12Clusters) {
            // FAT16 can handle the cluster count
            if (options.fat32) {
                // Requested FAT32; set free clusters to FAT32 minimum
                numClusters = MaxFAT16Clusters + 1;
            } else if (options.fat12) {
                // Requested FAT12; bump the cluster size
                newClusterSize *= 2;
            } else {
                newFATSize = 16;
            }
        } else {
            // FAT12 can handle the cluster count
            if (options.fat32) {
                // Requested FAT32; set free clusters to FAT32 minimum
                numClusters = MaxFAT16Clusters + 1;
            } else if (options.fat16) {
                // Requested FAT16; set free clusters to FAT16 minimum
                numClusters = MaxFAT12Clusters + 1;
            } else {
                newFATSize = 12;
            }
        }
        // Accept these settings if we can
        if (newFATSize == fatSize && newClusterSize == clusterSize) {
            break;
        }
        // If we need to bump the cluster size, but either the user specified
        // a cluster size or the new size is too large, then fail
        if (newClusterSize > clusterSize) {
            if (options.clusterSize != 0
            ||  clusterSize >= 128 * options.sectorSize) {
                error(format("Volume is too large for %u-byte clusters and FAT%u",
                        clusterSize, fatSize));
            }
        }
        fatSize = newFATSize;
        clusterSize = newClusterSize;
    }

    // Check for overflowing root directory
    if (options.rootDirSize != 0 && numDirEntries > options.rootDirSize
    &&  fatSize != 32) {
        error(format("Root directory size is %u, exceeding the limit of %u",
                numDirEntries, options.rootDirSize));
    }

    // Open the volume for writing
    if (options.output.empty) {
        options.output = "dos-volume.img";
    }
    auto volume = File(options.output, "wb");
    ulong usedClusters;
    try {
        // Extend the volume to the configured size
        volume.seek(endOfVolume * options.sectorSize - 1);
        volume.rawWrite([ cast(ubyte)(0) ]);

        // Write the master boot record if requested
        if (options.partitioned) {
            ubyte[512] mbr;

            mbr[0..$] = 0;

            mbr[0x1BE] = 0x00;
            ulong num = bootSector;
            auto sector = num % options.sectorsPerTrack + 1;
            num /= options.sectorsPerTrack;
            auto head = num % options.numHeads;
            auto cyl = num / options.numHeads;
            mbr[0x1BF] = cast(ubyte)(head);
            mbr[0x1C0] = cast(ubyte)(sector | ((cyl & 0x300) >> 2));
            mbr[0x1C1] = cast(ubyte)(cyl & 0xFF);
            ubyte type;
            switch (fatSize) {
            case 12:
                type = 0x01;
                break;

            case 16:
                type = ((endOfVolume - bootSector) >= 65536) ? 0x06 : 0x04;
                break;

            case 32:
                type = 0x0C;
                break;

            default:
                assert(0);
            }
            mbr[0x1C2] = type;
            num = endOfVolume - 1;
            sector = num % options.sectorsPerTrack + 1;
            num /= options.sectorsPerTrack;
            head = num % options.numHeads;
            cyl = num / options.numHeads;
            mbr[0x1C3] = cast(ubyte)(head);
            mbr[0x1C4] = cast(ubyte)(sector | ((cyl & 0x300) >> 2));
            mbr[0x1C5] = cast(ubyte)(cyl & 0xFF);
            setNumber(mbr[0x1C6..0x1CA], bootSector);
            setNumber(mbr[0x1CA..0x1CE], endOfVolume - bootSector);

            mbr[510] = 0x55;
            mbr[511] = 0xAA;

            volume.seek(0);
            volume.rawWrite(mbr);
        }

        // Write the directories, including the root directory, and the files
        auto fat = dir.writeVolume(volume, rootDirSector * options.sectorSize,
                firstDataSector * options.sectorSize, clusterSize);
        usedClusters = fat.length - 2;

        // Write the FATs
        auto mediaDesc = to!ubyte(options.mediaDesc, 16);
        fat[0] = 0xFFFFFF00 | mediaDesc;
        foreach (uint i; 0..options.numFATs) {
            volume.seek((firstFATSector + fatSectors*i)*options.sectorSize);

            switch (fatSize) {
            case 12:
                {
                    uint bits = 0xFFFFFFFF;
                    foreach (uint b; fat) {
                        if (bits == 0xFFFFFFFF) {
                            bits = b & 0xFFF;
                        } else {
                            bits |= (b & 0xFFF) << 12;
                            ubyte[3] bytes;
                            setNumber(bytes, bits);
                            volume.rawWrite(bytes);
                            bits = 0xFFFFFFFF;
                        }
                    }
                    if (bits != 0xFFFFFFFF) {
                        ubyte[2] bytes;
                        setNumber(bytes, bits);
                        volume.rawWrite(bytes);
                    }
                }
                break;

            case 16:
                {
                    ubyte[2] bytes;
                    foreach (uint b; fat) {
                        setNumber(bytes, b & 0xFFFF);
                        volume.rawWrite(bytes);
                    }
                }
                break;

            case 32:
                {
                    ubyte[4] bytes;
                    foreach (uint b; fat) {
                        setNumber(bytes, b & 0x0FFFFFFF);
                        volume.rawWrite(bytes);
                    }
                }
                break;

            default:
                assert(0);
            }
        }

        // Write the boot record
        auto bootrec = new ubyte[options.sectorSize];

        if (!options.bootRecord.empty) {
            auto brfile = File(options.bootRecord, "rb");
            brfile.rawRead(bootrec);
        } else {
            // A minimal, temporary boot record
            bootrec[0x00] = 0xEB;       // JMP
            bootrec[0x01] = 0x5A-0x02;
            bootrec[0x02] = 0x90;       // NOP
            bootrec[0x5A] = 0xEB;
            bootrec[0x5B] = 0xFE;
            if (options.sectorSize >= 512) {
                bootrec[0x1FE] = 0x55;
                bootrec[0x1FF] = 0xAA;
            }
        }

        uint extBPB = (fatSize == 32) ? 0x40 : 0x24;

        // OEM name
        if (options.oemName.empty) {
            options.oemName = "MSWIN4.1";
        }
        setString(bootrec[0x03..0x0B],
                options.oemName.empty ? "MSWIN4.1" : options.oemName);
        setNumber(bootrec[0x0B..0x0D], options.sectorSize);
        setNumber(bootrec[0x0D..0x0E], sectorsPerCluster);
        setNumber(bootrec[0x0E..0x10], reservedSectors);
        setNumber(bootrec[0x10..0x11], options.numFATs);
        setNumber(bootrec[0x11..0x13], (firstDataSector - rootDirSector) * options.sectorSize / 32);
        auto numSectors = endOfVolume - bootSector;
        if (numSectors < 0xFFFF) {
            setNumber(bootrec[0x13..0x15], numSectors);
            setNumber(bootrec[0x20..0x24], 0U);
        } else {
            setNumber(bootrec[0x13..0x15], 0U);
            setNumber(bootrec[0x20..0x24], numSectors);
        }
        bootrec[0x15] = mediaDesc;
        if (fatSize == 32) {
            setNumber(bootrec[0x16..0x18], 0U);
            setNumber(bootrec[0x24..0x28], fatSectors);
        } else {
            setNumber(bootrec[0x16..0x18], fatSectors);
        }
        setNumber(bootrec[0x18..0x1A], options.sectorsPerTrack);
        setNumber(bootrec[0x1A..0x1C], options.numHeads);
        setNumber(bootrec[0x1C..0x1F], hiddenSectors);

        if (fatSize == 32) {
            bootrec[0x28..0x2B] = 0;
            setNumber(bootrec[0x2C..0x30], dir.rootDirStart());
            setNumber(bootrec[0x30..0x32], 1U);
            setNumber(bootrec[0x32..0x34], 6U);
            bootrec[0x34..0x3F] = 0;
        }

        bootrec[extBPB+0x00] = options.partitioned ? 0x80 : 0x00;
        bootrec[extBPB+0x01] = 0;
        bootrec[extBPB+0x02] = 0x29;
        uint snum = serialNum(options.serial);
        setNumber(bootrec[(extBPB+3)..(extBPB+7)], snum);
        if (options.label.empty) {
            options.label = "NO NAME";
        }
        auto label = (options.label ~ "           ")[0..11];
        foreach (uint i; 0..11) {
            bootrec[extBPB+0x07+i] = label[i];
        }
        setString(bootrec[(extBPB+0x12)..(extBPB+0x1A)],
                format("FAT%2u", fatSize));

        volume.seek(bootSector * options.sectorSize);
        volume.rawWrite(bootrec);

        // For FAT32: write the FSInfo sector structure and the backup boot
        // sectors
        if (fatSize == 32) {
            ubyte[512] fsinfo;

            fsinfo[0..$] = 0;
            setString(fsinfo[0..4], "RRaA");
            setString(fsinfo[484..488], "rrAa");
            auto freeClusters = numClusters + 2 - fat.length;
            setNumber(fsinfo[488..492], freeClusters);
            auto nextCluster = fat.length + 2;
            setNumber(fsinfo[492..496], nextCluster);
            fsinfo[510] = 0x55;
            fsinfo[511] = 0xAA;

            volume.seek((bootSector+1) * options.sectorSize);
            volume.rawWrite(fsinfo);
            volume.seek((bootSector+6) * options.sectorSize);
            volume.rawWrite(bootrec);
            volume.seek((bootSector+7) * options.sectorSize);
            volume.rawWrite(fsinfo);
        }
    }
    finally {
        volume.close();
    }

    if (options.verbose) {
        writef("Volume %s complete\n", options.output);
        writef("Format: FAT%02u\n", fatSize);
        writef("Sector size: %u\n", options.sectorSize);
        writef("Cluster size: %u\n", clusterSize);
        writef("Clusters: %u used out of %u\n", usedClusters, numClusters);
        if (fatSize != 32) {
            writef("Root directory: %u used out of %u\n",
                    dir.numRootDirEntries(),
                    (firstDataSector - rootDirSector) * options.sectorSize / 32);
        }
    }

    return 0;
}
