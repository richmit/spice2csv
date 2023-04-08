#!/usr/bin/env -S ruby
# -*- Mode:ruby; Coding:us-ascii-unix; fill-column:158 -*-
#########################################################################################################################################################.H.S.##
##
# @file      spiceExportToCSV.rb
# @author    Mitch Richling http://www.mitchr.me/
# @date      2023-04-08
# @version   VERSION
# @brief     Convert exported text files from ngspice/LTspice into usefull CSVs.@EOL
# @keywords  spice
# @std       Ruby_3
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
printTitles = true
maxPrtLines = nil
prtColsNam     = nil
separator   = ','
unseparator = ';'
outFileName = '-'
opts = OptionParser.new do |opts|
  opts.banner = "spiceExportToCSV.rb -- Transform SPICE exported text to CSV          "
  opts.separator "                                                                    "
  opts.separator "SYNOPSIS                                                            " 
  opts.separator "  spiceExportToCSV.rb [OPTIONS] INPUT_FILE                          "
  opts.separator "                                                                    "
  opts.separator "DESCRIPTION                                                         " 
  opts.separator "  Transform SPICE transient analysis exported text into simple CSV  "
  opts.separator "                                                                    "
  opts.separator "  Both LTspice and ngspice have simple text export options:         "
  opts.separator "   - LTspice                                                        "
  opts.separator "      - Accessed via the menu option 'Export data as text' found    "
  opts.separator "        in the 'File' menu produces a simple TSV (Tab Separated     "
  opts.separator "        Values) file.                                               "
  opts.separator "      - The line endings are CRLF                                   "
  opts.separator "   - ngspice                                                        "
  opts.separator "      - Accessed via the =wrdata= command.                          "
  opts.separator "         - The Option =numdgt= controls the number of digits.       "
  opts.separator "         - The variable =wr_singlescale= prints time data once      "
  opts.separator "         - The variable =wr_vecnames= adds column titles            "
  opts.separator "           Note: This script expects titles!                        "
  opts.separator "      - The file is whitespace separated.                           "
  opts.separator "      - The line endings are CRLF On Windows, and LF on UNIX        "
  opts.separator "  What are 'simple' CSV files?                                      "
  opts.separator "   - Titles are simplified.                                         "
  opts.separator "      - V(foo) is replaced by V_foo                                 "
  opts.separator "      - I(foo) is replaced by I_foo                                 "
  opts.separator "      - Commas are replaced by semicolons                           "
  opts.separator "      - No quotes around titles                                     "
  opts.separator "      - Leading slashes are removed (i.e. KiCad-type node names)    "
  opts.separator "   - Step columns are added if the data is stepped                  "
  opts.separator "      - The step columns may be used as a factor in R               "
  opts.separator "      - Units are converted                                         "
  opts.separator "      - Only works for LTspice                                      "
  opts.separator "                                                                    "
  opts.separator "OPTIONS                                                             " 
  opts.on("-h",             "--help",              "Show this message")               { STDERR.puts opts; exit               }
  opts.on("-o OUT_FILE",    "--out OUT_FILE",      "Name of output file")             { |v| outFileName = v;                 }
  opts.separator "         Valid values: single, double                               "                                   
  opts.separator "         If not provided, STDOUT is used.                           "                                   
  opts.separator "         The string '-' is a synonym for STDOUT.                    "                                   
  opts.on("-t",             "--no-titles",         "Do not print CSV titles")         { |v| printTitles = false;             }
  opts.on("-n LINES",       "--lines LINES",       "Maximum number of output lines")  { |v| maxPrtLines = v.to_i;            }
  opts.separator "         Use 1 to just print titles                                 "
  opts.on("-c COLS",        "--cols COLS",         "List of columns to print")        { |v| prtColsNam = v.split(separator); }
  opts.separator "         List is separated with the output separator.  Uses the     "
  opts.separator "         separator provided by the -s option *if* the -s option     "
  opts.separator "         appears before this one. Otherwise a comma is used.        "
  opts.separator "         Columns are printed in the order given!                    "
  opts.on("-s SEPARATOR",   "--sep SEPARATOR",     "Separator to use for output")     { |v| separator = v;                   }
  opts.separator "         Default: comma                                             "
  opts.on("-u UNSEPARATOR", "--unsep UNSEPARATOR", "Used to fix variable names")      { |v| unseparator = v;                 }
  opts.separator "         Default: semicolon                                         "
  opts.separator "                                                                    "
end
opts.parse!(ARGV)

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
sufx = { "f"   => 1e-15,
         "T"   => 1e12,
         "p"   => 1e-12,
         "G"   => 1e9,
         "n"   => 1e-9,
         "Meg" => 1e6,
         "u"   => 1e-6,
         "K"   => 1e3,
         "M"   => 1e-3,
         "Mil" => 25.4e-6,
         nil   => 1
       }

################################################################################################################################################################
needToPrintHeader = printTitles
open(inFileName, "rb") do |file|
  fileTitles = file.readline.strip.split.map {|x| x.strip.sub(/^([vViI])\(\/*(.+)\)$/, '\1_\2').sub(/([vViI])\(\/*([^)]+)\)/, '\1_\2').sub(separator, unseparator).sub(/^"(.+)"$/, '\1').sub(/^\//, '') }
  stepTitles = Array.new
  stepValues = Array.new
  allTitlesArray = nil
  allTitlesArry = nil
  allTitlesHash = nil

  linesPrinted = 0;
  file.each_line do |line|
    if tmp=line.match(/^Step Information:(.+)\(Run:.*$/) then
      stepData = tmp[1].strip.split.map {|x| x.split('=')}
      stepTitles = stepData.map {|x| x[0]}
      stepValues = stepData.map {|x| x[1]}
    else
      if linesPrinted == 0 then
        allTitlesArry = (fileTitles + stepTitles)
        allTitlesHash = allTitlesArry.zip((0..(allTitlesArry.length-1)).to_a).to_h
        prtColsNam    = (prtColsNam || allTitlesArry)
        prtColsNum    = prtColsNam.map { |x| allTitlesHash[x] ||
                                         begin
                                           STDERR.puts("ERROR: Requested column not found in file: '#{x}'!"); 
                                           exit
                                         end }
        if (printTitles) then
          outFile.puts(prtColsNam.join(','))
        end
        linesPrinted += 1
      end
      outFile.puts( ((line.strip.split + stepValues).map {|x| tmp = x.match(/^([^GKMTfnpu]+)(f|T|p|G|n|Meg|u|K|M|Mil)?$/); tmp[1].to_f * sufx[tmp[2]]; }).values_at(*prtColsNum).join(',') )
      linesPrinted += 1
      if (maxPrtLines && (linesPrinted >= maxPrtLines)) then
        break
      end
    end
  end
end
