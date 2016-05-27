browser-suspender
=================

#### Suspend out-of-focus browser (Firefox) to save battery from useless CPU usage.

Based on script from <http://log.or.cz/?p=356>


Firefox is constantly spinning and eating CPU when it's supposed to just sit idle. This could reduce battery life considerably.
This shell script will periodically assess the situation and suspend or resume Firefox as needed.


It will stop Firefox process when it's window is out of focus for more than 10s and on battery, and resume it when switching back.
The script can handle multiple Firefox processes/profiles and resumes all processes on it's exit.
You can run it in a terminal or backgrounded from your `~/.xsessionrc`


Linux/Unix only.
