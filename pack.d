// pack.d -- packers for numbers and strings
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

import std.traits;

// Set a numeric value in a byte array
void
setNumber(numtype)(ubyte[] bytes, numtype num)
if (isIntegral!numtype | isSomeChar!numtype)
{
    auto n = Unconst!numtype(num);

    foreach (i; 0..bytes.length) {
        bytes[i] = cast(ubyte)(n & 0xFF);
        n >>= 8;
    }
    assert(n == 0);
}

// Set a string in a byte array, with truncation or space padding
void
setString(ubyte[] bytes, string str)
{
    if (bytes.length < str.length) {
        foreach (i; 0..bytes.length) {
            bytes[i] = str[i];
        }
    } else {
        foreach (i; 0..str.length) {
            bytes[i] = str[i];
        }
        bytes[str.length..$] = ' ';
    }
}
