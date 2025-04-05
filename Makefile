# Makefile for genfatimage
#
# Copyright © 2025 Ray Chason.
# 
# This file is part of genfatimage.
# 
# genfatimage is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 3, or (at your option) any later
# version.
# 
# genfatimage is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
# 
# You should have received a copy of the GNU General Public License
# along with genfatimage; see the file LICENSE.  If not see
# <http://www.gnu.org/licenses/>.

OFILES = genfatimage.o directory.o unicode.o pack.o

EXE = genfatimage

DC = gdc
DFLAGS = -Wall -O2

$(EXE) : $(OFILES)
	$(DC) -o $(EXE) $(OFILES)

genfatimage.o : genfatimage.d directory.d unicode.d pack.d
	$(DC) $(DFLAGS) -c $< -o $@

directory.o : directory.d unicode.d pack.d
	$(DC) $(DFLAGS) -c $< -o $@

unicode.o : unicode.d
	$(DC) $(DFLAGS) -c $< -o $@

pack.o : pack.d
	$(DC) $(DFLAGS) -c $< -o $@

clean:
	rm -f *.o $(EXE)
