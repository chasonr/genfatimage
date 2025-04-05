# genfatimage #

genfatimage creates FAT file systems with user-specified contents. Users can create FAT12, FAT16 and FAT32 images; images with sector sizes other than 512; and images with a partition table covering a single partition.
Long file names are fully supported. Presets are provided for common floppy disk formats.

## Needed to build and run ##

genfatimage is written in D and built with the gdc compiler. No attempt has been made to compile with dmd.

The compiled program requires the libgphobos library, and you will need the package that contains this library. On Debian and its descendants, this package is libgphobos4.
