# ================================================================================
#
# Build ID Verilog Module Script
# Jeff Wiencrot - 8/1/2011
#
# Generates a Verilog module that contains a timestamp, used by the
# `BUILD_DATE macro in Saturn_MiST.sv's CONF_STR version string.
#
# ================================================================================

proc generateBuildID_Verilog {} {

	# Get the timestamp (see: http://www.altera.com/support/examples/tcl/tcl-date-time-stamp.html)
	set buildDate [ clock format [ clock seconds ] -format %y%m%d ]
	set buildTime [ clock format [ clock seconds ] -format %H%M%S ]

	# Create a Verilog file for output
	set outputFileName "build_id.v"
	set outputFile [open $outputFileName "w"]

	# Output the Verilog source
	puts $outputFile "`define BUILD_DATE \"$buildDate\""
	puts $outputFile "`define BUILD_TIME \"$buildTime\""
	close $outputFile

	# Send confirmation message to the Messages window
	post_message "Generated build identification Verilog module: [pwd]/$outputFileName"
	post_message "Date:             $buildDate"
	post_message "Time:             $buildTime"
}

generateBuildID_Verilog
