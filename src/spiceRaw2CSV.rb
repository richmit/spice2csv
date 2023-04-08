#!/usr/bin/env -S ruby
# -*- Mode:ruby-mode; Coding:us-ascii-unix; fill-column:158 -*-
#########################################################################################################################################################.H.S.##
##
# @file      spiceRaw2CSV.rb
# @author    Mitch Richling http://www.mitchr.me/
# @brief     Convert spice transient analysis raw files into CSVs.@EOL
# @keywords  
# @std       Ruby 3
# @see       
# @copyright 
#  @parblock
#  Copyright (c) 2023, Mitchell Jay Richling <http://www.mitchr.me/> All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
#
#  1. Redistributions of source code must retain the above copyright notice, this list of conditions, and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and the following disclaimer in the documentation
#     and/or other materials provided with the distribution.
#
#  3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without
#     specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
#  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
#  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
#  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#  @endparblock
# @todo      Add support for FastAccess.@EOL@EOL
# @warning   Only tested with ngspice & LTspice.@EOL@EOL
# @bug       FastAccess is not supported.@EOL@EOL
# @filedetails
#
#  WHAT AND WHY
#  ^^^^^^^^^^^^
#  
#  I work with circuits implementing dynamical systems.  Usually old school analog computer implementations of differential
#  equations, but also more fundamental circuits with just simple transistors.  As such I do quite a lot of transient analysis with
#  SPICE.  Unfortunately many of the dynamical systems in which I'm interested are expressed as more than two equations.  So I need
#  to go beyond the 2D plotting capabilities of most SPICE plotting systems.  This script forms the first part of a chain to convert
#  SPICE raw files containing transient analysis data into CSV files other tools can consume.  What other tools?  Mostly Paraview,
#  ViSit, Maple, & GNUPlot.
#  
#  SPICE RAW FILE OVERVIEW
#  ^^^^^^^^^^^^^^^^^^^^^^^
#  
#  The SPICE RAW file format is composed of a sequence of named data sections.  Each section starts with a label.  These labels start
#  in column 0.  The labels themselves always begin with an alphabetic character.  The end of a label is marked by the first colon
#  found on the label line.  After the colon a single value *may* be found, and this value might contain a colon -- hence the "first"
#  in the previous sentence.  Additional values may be found on subsequent lines.  These additional value lines always start with
#  whitespace.  The final section is "Values" for ASCII files, and "Binary" for binary ones.
#  
#  The text encoding might be ASCII, UTF8, UTF16LE.  The line endings might be LF, CR, or CRLF.  I use the text processing
#  facilities of Ruby which have some magic on Windows -- CRLF & LF are treated transparently.  On UNIX, DOS files might not be
#  processed properly -- so use a dos2unix tool first if things go wrong processing DOS/Windows files.
#  
#  IMPORTANT SPICE RAW DATA SECTIONS
#  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#  
#   - Title: Generally the first line of the file.  For LTspice it contains the path of the .asc file.
#   - Plotname: Type of simulation.  This tool requires this value to be "Transient Analysis"
#   - Flags: This is a list of flags.  Of importance are the following two:
#      - "stepped" LTspice uses this to indicate the use of .STEP
#      - "fastaccess" LTspice uses this to indicate the binary file is reorganized
#   - No. Variables:  Number of variables in data set
#   - No. Points: Number of points per variable
#   - Variables: List of variables
#      - No data value on the label line!
#      - Each variable is on a new line containing: variable index integer, variable name, and variable data type -- separated by tabs
#   - Values: Data values follow (ascii mode)
#      - Time step tuple starts with an integer time step index 
#      - In LTspice the time step starts in column zero.  
#      - In ngspice it is proceeded by a single space
#      - The first value for the tuple follows a tab after the time step integer
#      - The remaining tuple components are each on a separate line.  Each value is preceded by whitespace.
#   - Binary: Data values follow (binary mode)
#      - The file is repeated blocks like: <timestamp><data 1>...<data N>
#      - Timestamps are 8 byte floats (double)
#      - Data are 4 or 8 byte floats (single)
#        - In LTspice, singles are used when numdgt<7 and doubles otherwise
#      - The endianness is normally determined by the native platform -- in old SPICE this was FORTRAN binary IO.
#      - Fast Access mode is an LTspice feature I may someday support in the future   
#         - Format is: <timestamp 1><timestamp 1>...<timestamp M><trace1 0><trace1 1>...<trace1 M>...<traceN 0><traceN 1>...<traceN M>
#
#########################################################################################################################################################.H.E.##

################################################################################################################################################################
require 'socket'
require 'fileutils'
require 'set'
require 'optparse'
require 'optparse/time'

################################################################################################################################################################
# Print stuff to STDOUT immediatly -- important on windows
$stdout.sync = true

################################################################################################################################################################
# Parse command line arguments
debugLevel  = 1
printTitles = true
maxPrtLines = nil
ovrEnd      = nil
separator   = ','
unseparator = ';'
prtCols     = nil
floatSizes  = nil
outFileName = '-'
opts = OptionParser.new do |opts|
  opts.banner = "spiceRaw2CSV.rb -- Extract data from SPICE raw files to CSV          "
  opts.separator "                                                                    "
  opts.separator "SYNOPSIS                                                            " 
  opts.separator "  spiceRaw2CSV.rb <OPTIONS> INPUT_FILE                              "
  opts.separator "                                                                    "
  opts.separator "DESCRIPTION                                                         " 
  opts.separator "                                                                    "
  opts.separator "  Extract one or more variables from supported spice raw files:     "
  opts.separator "    - Spice versions tested: xyce, ngspice & LTspice                "
  opts.separator "    - Transient Analysis is the only analysis supported             "
  opts.separator "    - Endianness automatically detected for binary                  "
  opts.separator "    - Binary float size is automatically detected                   "
  opts.separator "    - ASCII & UTF16LE are supported and automatically detected      "
  opts.separator "    - On Windows, line endings are usually magically detected       "
  opts.separator "    - LTspice:                                                      "
  opts.separator "      - FastAccess is detected, but not supported (yet)             "
  opts.separator "      - Stepped (.STEP) files are supported                         "
  opts.separator "      - Time offset is automatically detected                       "
  opts.separator "      - Compressed files are *NOT* supported                        "
  opts.separator "        Add: .option plotwinsize=0                                  "
  opts.separator "                                                                    "
  opts.separator "OPTIONS                                                             " 
  opts.on("-h",             "--help",              "Show this message")               { STDERR.puts opts; exit            }
  opts.on("-o OUT_FILE",    "--out OUT_FILE",  "Name of output file")                 { |v| outFileName = v;              }
  opts.separator "         Valid values: single, double                               "                                   
  opts.separator "         If not provided, STDOUT is used.                           "                                   
  opts.separator "         The string '-' is a synonym for STDOUT.                    "                                   
  opts.on("-d DEBUG_LEVEL", "--debug DEBUG_LEVEL", "Debug Level")                     { |v| debugLevel = v.to_i;          }
  opts.separator "          1 -- Errors -- program will exit                          "                                   
  opts.separator "          5 -- Print metadata                                       "                                   
  opts.separator "         10 -- Print more metadata                                  "                                   
  opts.separator "          1 -- DEFAULT!                                             "                                   
  opts.on("-t",             "--no-titles",         "Do not print CSV titles")         { |v| printTitles = false;          }
  opts.on("-n LINES",       "--lines LINES",       "Maximum number of output lines")  { |v| maxPrtLines = v.to_i;         }
  opts.separator "         Use 1 to just print titles                                 "
  opts.on("-c COLS",        "--cols COLS",         "List of columns to print")        { |v| prtCols = v.split(separator); }
  opts.separator "         COLS is a list of column names separated with the          " 
  opts.separator "         *current* output separator.  i.e. it will use a comma      "
  opts.separator "         unless an -s option changeing the separator appears        "
  opts.separator "         *before* this option on the command line.  Columns are     "
  opts.separator "         printed in the order given!  Column titles are printed     "
  opts.separator "         EXACTLY as given; however, string comparisons when         "
  opts.separator "         locating variables in the raw file are case                "
  opts.separator "         insensitive.  Two columns are available that do not        "
  opts.separator "         correspond to variables:                                   "
  opts.separator "           - idx -- The zero based index of the point in the file   "
  opts.separator "           - stp -- The zero based step number (for .step)          "
  opts.separator "                    Always 0 if no .step directive                  "
  opts.separator "         If this option is not provided, then all variables and     "
  opts.separator "         the 'idx' columns are printed.  In addition, for           "
  opts.separator "         stepped files, the 'stp' column will be printed. The       "
  opts.separator "         order will be 'stp' (if printed), 'idx', and the           "
  opts.separator "         remainder of the variables in the order they appear in     "
  opts.separator "         the file.                                                  "
  opts.on("-s SEPARATOR",   "--sep SEPARATOR",     "Separator to use for output")     { |v| separator = v;                }
  opts.separator "         Default: comma                                             "
  opts.on("-u UNSEPARATOR", "--unsep UNSEPARATOR", "Used to fix variable names")      { |v| unseparator = v;              }
  opts.separator "         Default: semicolon                                         "
  opts.on("-e ENDIANNESS",  "--endian ENDIANNESS", "Endianness for binary files")     { |v| ovrEnd = v;                   }
  opts.separator "         Valid values: big, little                                  "                                   
  opts.separator "         If not provided, use current system's endianness           "                                   
  opts.on("-f SIZE",             "--floats SIZE",  "Size of binary floats")           { |v| floatSizes = v;               }
  opts.separator "         Valid values: single, double                               "                                   
  opts.separator "         If not provided, guess based on file size                  "                                   
  opts.separator "                                                                    "
end
opts.parse!(ARGV)

if (separator == unseparator) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: Separator & Unseparator can't be the same: #{separator.inspect}"); end
  exit
end

if (ovrEnd && (ovrEnd != 'big') && (ovrEnd != 'little'))then
  if (debugLevel >= 1) then STDERR.puts("ERROR: The --endian option must be 'big' or 'little', and not #{ovrEnd.inspect}"); end
  exit
end

inFileName = ARGV[0];
inFileSize = FileTest.size?(inFileName)
if (inFileSize.nil?) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: Could not stat input file: #{inFileName.inspect}"); end
  exit
end

outFile = STDOUT
if (outFileName != '-') then
  outFile = open(outFileName, 'wt')
  if (outFile.nil?) then
    if (debugLevel >= 1) then STDERR.puts("ERROR: Failed to open output file: #{outFileName.inspect}"); end
    exit
  end
end

################################################################################################################################################################
# First we figure out the encoding...
textOpenF    = nil
open(inFileName, "rb") do |file|
  tmp = file.read(6);
  if (tmp == 'Title:') then
    textOpenF = 'rb'
  elsif (tmp.force_encoding('UTF-16LE').encode('ASCII-8BIT') == 'Tit') then
    textOpenF = 'rb:UTF-16LE:UTF-8'
  else
    if (debugLevel >= 1) then STDERR.puts("ERROR: Coudln't detected input text encoding -- or it might not be a SPICE raw file..."); end
    exit
  end
end

################################################################################################################################################################
# First we extract the meta data from the file, determin the file type (binary/text), grab a few bits of data, and locate the start of the data.
metaData = Hash.new
dataStart = nil
numVars = nil
numPoints = nil
fileType = nil
timeOff  = nil
open(inFileName, textOpenF) do |file|
  sectionName = nil
  loop do
    line = file.readline
    if (mDat = line.match(/^([A-Za-z][^:]+):\s*(.*)/)) then
      sectionName  = mDat[1]
      sectionValue = mDat[2].strip
      if (sectionName == 'Values') then
        fileType = 'ascii'
        dataStart = file.pos
        break
      elsif (sectionName == 'Binary') then
        fileType = 'binary'
        dataStart = file.pos()
        break
      else
        if (sectionValue.empty?) then
          metaData[sectionName] = Array.new
        else
          metaData[sectionName] = [ sectionValue ]
        end
      end
    else
      if (sectionName) then
      metaData[sectionName].push(line.strip);
      else
    if (debugLevel >= 1) then STDERR.puts("ERROR: Found dangleing data with no section name: #{line.inspect}"); end
        exit
      end
    end
  end
end

if ( !(fileType)) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: File did not have data (no Values or Binary section)"); end
  exit
end

if (metaData.member?('Plotname')) then
  if (metaData['Plotname'].first != 'Transient Analysis') then
    if (debugLevel >= 1) then STDERR.puts("ERROR: Only transient analysis (.tran) is supported.  Found:  #{metaData['Plotname'].inspect}"); end
    exit
  end
else
  if (debugLevel >= 1) then STDERR.puts("ERROR: No analysis type found (no Plotname line)"); end
  exit
end

if ( !(metaData.member?('Variables'))) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: No variable description section!"); end
  exit
end

if (metaData.member?('No. Variables')) then
  numVars = metaData['No. Variables'].first.to_i
else
    if (debugLevel >= 1) then STDERR.puts("ERROR: No varible count found!"); end
  exit
end

if (metaData.member?('No. Points')) then
  numPoints = metaData['No. Points'].first.to_i
else
    if (debugLevel >= 1) then STDERR.puts("ERROR: No point count found!"); end
  exit
end

fileIsStepped    = false
fileIsFastAccess = false
fileIsCompressed = false
if (metaData.member?('Flags')) then
  if (metaData['Flags'].first().match('fastaccess')) then
    fileIsFastAccess = true
  end
  if ((metaData.member?('Command')) && (metaData['Command'].first().match('LTspice'))) then
    if ( !(metaData['Flags'].first().match('nocompression'))) then
    fileIsCompressed = true
  end
end
  if (metaData['Flags'].first().match('stepped')) then
    fileIsStepped = true;
  end
end

if (metaData.member?('Offset')) then
  timeOff = metaData['Offset'].first().to_f()
end

################################################################################################################################################################
if (debugLevel >= 5) then 
  STDERR.puts("File encoding ... #{textOpenF.inspect}")
  STDERR.puts("Data starts at .. #{dataStart.inspect}")
  STDERR.puts("Num variables ... #{numVars.inspect}")
  STDERR.puts("Num points ...... #{numPoints.inspect}")
  STDERR.puts("File Type ....... #{fileType.inspect}")
  STDERR.puts("Stepped file .... #{fileIsStepped.inspect}")
  STDERR.puts("Fast Access ..... #{fileIsFastAccess.inspect}")
  STDERR.puts("Compressed ...... #{fileIsCompressed.inspect}")
  STDERR.puts("Time Offset ..... #{timeOff.inspect}");
  STDERR.puts("Variables:")
  metaData['Variables'].each do |vLine|
    vIdx, vName, vType = vLine.split("\t")
    STDERR.printf("   %3d %-11s %s\n", vIdx.to_i, vType, vName)
  end
end
if (debugLevel >= 10) then 
  STDERR.puts("File Metadata:")
  metaData.each do |k, v|
    STDERR.puts("   #{k.inspect} => #{v.inspect}")
  end
end

################################################################################################################################################################
# I don't use FastAccess, but I may add support some day...
if (fileIsFastAccess) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: FastAccess files are not supported!"); end
  exit
end

################################################################################################################################################################
# We don't support compressed files!
if (fileIsCompressed) then
  if (debugLevel >= 1) then STDERR.puts("ERROR: LTspice compresseded files are not supported!"); end
  exit
end

################################################################################################################################################################
# Print headings
variableNames  = (metaData['Variables'].map { |v| v.split("\t")[1].gsub(separator, unseparator); })
allTitlesArray = ['stp', 'idx'] + variableNames;
allTitlesHash  = allTitlesArray.map(&:downcase).zip((0..(allTitlesArray.length-1)).to_a).to_h
if (prtCols.nil?) then
  prtCols = (fileIsStepped ? ['stp', 'idx'] : ['idx']) + variableNames
end

outFile.puts(prtCols.join(separator));

# Convert prtCols from column names to column indexes.
prtCols.map! do |vName| 
  allTitlesHash[vName.downcase] ||
    begin
      if (debugLevel >= 1) then STDERR.puts("ERROR: Requested column not found in file: '#{vName}'!"); end
      exit
    end
end

################################################################################################################################################################
# Exit if we don't need to print data
if (( !(maxPrtLines.nil?)) && (maxPrtLines < 2)) then
  exit
end

################################################################################################################################################################
# Extract and print data
numPtsPrint = (maxPrtLines.nil? ? numPoints : [ maxPrtLines-1, numPoints ].min)
stp         = 0;
stpOneTime  = nil;
if (fileType == 'ascii') then
  open(inFileName, textOpenF) do |file|
    file.seek(dataStart)
    1.upto(numPtsPrint) do |i|
      # Read lines till we get something with content.
      tmp = nil
      begin
        tmp = file.readline().strip
      end while (tmp.empty?)
      # Split the index and first value.  Initialize data.
      data = tmp.split(/\s+/)
      if (fileIsStepped) then
        if (stpOneTime.nil?) then
          stpOneTime = data[1]
        else
          if (data[1] == stpOneTime) then
            stp += 1;
            STDERR.puts("STEP: #{stp.inspect}");
          end
        end
      end
      data.prepend(stp.to_s)
      # Read remaining vars, and update data.
      1.upto(numVars - 1) do |j|
        data.push(file.readline().strip)
      end
      outFile.puts(data.values_at(*prtCols).join(separator))
    end
  end
else
  idx = 0;
  if (floatSizes.nil?) then
    floatSizes = ((1.0 * inFileSize - dataStart) / numPoints - 8) / (numVars-1)
  else
    floatSizes = (floatSizes == 'double' ? 8 : 4)
  end
  dFmt = (ovrEnd.nil? ? "d" : (ovrEnd == "big" ? "G" : "E") ); # "D" native "E" little-endian  "G" big-endian   Double
  sFmt = (ovrEnd.nil? ? "f" : (ovrEnd == "big" ? "g" : "e") ); # "f" native "e" little-endian  "g" big-endian  Single
  open(inFileName, "rb") do |file|
    file.seek(dataStart)
    sampSize  = 8    +  (floatSizes < 7 ? 4    : 8)    * (numVars-1);
    fmt       = dFmt + ((floatSizes < 7 ? sFmt : dFmt) * (numVars-1));
    if (debugLevel >= 10) then 
      STDERR.puts("File size ....... #{inFileSize}")
      STDERR.puts("Data size ....... #{inFileSize - dataStart}")
      STDERR.puts("Seek loc ........ #{dataStart}")
      STDERR.puts("Point size ...... #{(1.0*inFileSize - dataStart)/numPoints}")
    end
    if (debugLevel >= 5) then 
      STDERR.puts("Float size ...... #{floatSizes.inspect}")
    end
    if (debugLevel >= 10) then 
      STDERR.puts("Sample size ..... #{sampSize.inspect}")
      STDERR.puts("Sample fmt ...... #{fmt.inspect}")
    end
    1.upto(numPtsPrint) do |i|
      data = file.read(sampSize).unpack(fmt)
      if (timeOff) then
        data[0] += timeOff
      end
      outFile.puts(([stp, idx] + data).values_at(*prtCols).join(separator))
      idx += 1
    end
  end
end
