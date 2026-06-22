-- Haven — file the annual BIS/NSA encryption self-classification report.
-- Regenerates the report, prepares the email (with CSV attached), and offers to send.
set havenDir to "/Users/blainemiller/Documents/mine/Personal/Apps/Haven"
do shell script "/usr/local/bin/node " & quoted form of (havenDir & "/Scripts/export-compliance.mjs")
do shell script "tail -n +5 " & quoted form of (havenDir & "/Scripts/export-compliance/self-classification-email.txt") & " > /tmp/haven-report-body.txt"
set reportBody to (read POSIX file "/tmp/haven-report-body.txt" as «class utf8»)
set csvPath to havenDir & "/Scripts/export-compliance/self-classification-report.csv"

tell application "Mail"
	activate
	set m to make new outgoing message with properties {subject:"Annual Self-Classification Report — Blaine Miller", content:reportBody, visible:true}
	tell m
		make new to recipient at end of to recipients with properties {address:"crypt@bis.doc.gov"}
		make new to recipient at end of to recipients with properties {address:"enc@nsa.gov"}
		tell content
			make new attachment with properties {file name:(POSIX file csvPath)} at after the last paragraph
		end tell
	end tell
end tell

delay 1
display dialog "Your annual Haven encryption self-classification report is ready." & return & return & "Send it to crypt@bis.doc.gov and enc@nsa.gov now?" buttons {"Review only", "Send now"} default button "Send now" with title "Haven Export Compliance"
if button returned of result is "Send now" then
	tell application "Mail" to send m
	display notification "Self-classification report sent to BIS + NSA." with title "Haven Compliance ✓"
end if
