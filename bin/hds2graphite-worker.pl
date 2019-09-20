#!/usr/bin/perl
# =============================================================================
#
#  File Name        : hds2graphite.pl
#
#  Project Name     : HDS Grafana
#
#  Author           : Timo Drach
#
#  Platform         : Linux Perl
#
#  Initially written: 13.02.2017
#
#  Description      : Script imports the HDS Export Tool data of HDS storage systems to a grafana graphite backend.
#
# ==============================================================================================

use v5.10;
use strict;
use warnings;
use constant false => 0;
use constant true  => 1;

use File::stat;
use Getopt::Long;
use IO::Socket::INET;
use Log::Log4perl;
use POSIX ":sys_wait_h";
use POSIX qw(strftime ceil);
use Systemd::Daemon qw( -hard notify );
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use Time::Local;

# auto-flush on socket
$| = 1;

my $loglevel = "INFO";
my %args;  # variable to store command line options for use with getopts
my $log; # log4perl logger

my $logfile = ""; # Logfile definition => provided by config file
my $etlogfile = ""; # Logfile location for Export Tool => provided by config file

my $conf = ""; #location of the script configuration file => is passed to the script
my $serial = ""; # serial number of the storage system currently being imported => provided by config file
my $exportpath = ""; # folder containing the Export Tool output which should be importet => provided by config file or passed to the script
my $exporttoolretrycnt = 3; #defines retry count for Export Tool
my $exporttoolretrytimeout = 2; #defines retry timeout for Export Tool in minutes
my $horcminst = ""; # HORCM instance ID pointing to the storage system currently being imported => provided by config file
my $metricconf = ""; # configuration file containing the metrics which should be imported => provided by config file
my $storagename = ""; # name of the storage system currently being imported => passed to the script
my $noexporttool = false; # switch to activate or deactivate the Export Tool => set at runtime
my $hourstoimport = 1; # number of past hours of Export Tool data which should be => passed to the script
my $exporttoolstatus = true;

my $graphitehost = ""; # IP address or name of the Graphite host => provided by config file
my $graphiteport = ""; # Port of the Graphite host => provided by config file

my $cciuser = ""; # CCI user => provided by config file
my $ccipasswd = ""; # CCI passwd => provided by config file

my $usevirtualldev = false; #Flag to specify whether virtual LDEV IDs should be used for storing data of GAD volumes.

my $exporttoolpath = ""; # folder of the Export Tool matching the imported storage sytem type => provided by config file

my %namereference; # Hash mapping storage system and serial number => provided by config file and filled at runtime
my %arraytype; # Hash mapping storage system type and serial number => provided by config file and filled at runtime
my %cciinstances; # Hash mapping CCI/HORCM instance and serial number => provided by config file and filled at runtime
my %ccicredentials; # Hash including all CCI credentials for the storage arrays
my %metricfiles; # Hash with all metric files for all storage system types => provided by config file and filled at runtime
my %exporttooltemplates; # Hash with all Export Tool template files for one storage system type => provided by config file and filled at runtime
my %exporttoolparams; # Hash containing Export Tool params for all serial numbers => provided by config file
my %serialreference; # Reverse Hash maping serial number und name of the storage system => provided by config file and filled at runtime
my %vsms; # Refernce hash for Global Active Device - Virtual Storage Machine
my %graphiteconf;
my %serviceconf;

my %config; # Hash containing alle metric which should be currently imported => provided by config file and filled at runtime

my %poolstats; # Hash containing pool statistics of the storage system => filled at runtime
my @pgs; # Array containing all Parity Groups of the storage system => filled at runtime

my %ldevmapping; # Hash mapping all LDEVs and (HDP pools or Parity Groups) relations => filled at runtime
my %lumapping; # Hash mapping all LU and LDEV relations => filled at runtime
my %hsdreference; # Hash mapping HSD names and HSD Index ID relations => filled at runtime

my %systemips; # Hash containing all storage system IP addresses. SVP IP for VSP und G1x00, both controller IPs for Gx00. => filled at runtime from config file
my $starttime = time;

my $socketcnt = 0;
my $sockettimer;
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;

my $enablearchive = false;
my $archivepath = '/opt/hds2graphite/arch';
my $hourstopreserve = 24;

my $runeveryhours = 1;
my $minafterfullhours = 24;
my $lastsuccessfulrun = 0;
my $lastsuccessfulrunend = 0;
my $statusdir = '/opt/hds2graphite/run/';
my $serviceuser = 'openiomon';
my $openiomonuid = 0;
my $openiomongid = 0;

my $watchdog = 300;
# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts. The factor 0.9 adds in some tolerance to avaid watchdog is killing service because delay for inserts is to high! This might happen if the 1st 100.000 inserts are done in less than 2 seconds
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;

my $daemon = false;

my $socket;

# Helper-Sub to print console output and log to logfile

sub console {
    my $message = shift;
    if(!$daemon) {
        print $message,"\n";
    }
    $log->trace($message);
}

# Sub to print the parameter reference

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    print("   -conf <file>             conf file containig parameter for the import\n");
    print("   -storagesystem <name>    name of the storage system to be imported\n");
    print("   -hours <number of hours> number of hours that should be imported (between 1 and 23)\n");
    print("   -exportpath <dir>        points to directory where Export Tool data is stored for optional manual import\n");
    print("   -daemon                  used for starting the deamonized version of hds2graphitelog\n");
    print("   -h                       print this output\n");
    print("\n");
}

# Sub to parse the script parameters.

sub parseCmdArgs {
    my $help = "";
        GetOptions (    "conf=s"            => \$conf,          # String
                        "exportpath=s"      => \$exportpath,    # String
                        "storagesystem=s"   => \$storagename,   # String
                        "hours=s"           => \$hourstoimport, # String
                        "daemon"            => \$daemon,        # flag
                        "h"                 => \$help)          # flag
        or die("Error in command line arguments\n");

    # keine Konfigdatei => Script wird beendet.
    if($conf eq "") {
        printUsage();
        if($daemon) {
            stopservice();
        }
        exit(1);
    } else {
        # Read the config file
        readconfig();
    }
    if(($hourstoimport<=0) || ($hourstoimport >24)) {
        print ("Invalid nunber of hours specified: ".$hourstoimport."\n\n");
        printUsage();
        if($daemon) {
            stopservice();
        }
        exit(1);
    }
    # Missing storage system name will stop script
    if($storagename eq "") {
        printUsage();
        if($daemon) {
            stopservice();
        }
        exit(1);
    } else {
        # get storage system serial and CCI instance out of the config data
        if(defined $cciinstances{uc($storagename)}) {
            $horcminst = $cciinstances{uc($storagename)};
        } else {
            print("Can get CCI Instance for Storagesystem: ".$storagename."\n");
            if($daemon) {
                stopservice();
            }
            exit(1);
        }
        if(defined $serialreference{uc($storagename)}) {
            $serial = $serialreference{uc($storagename)};
        } else {
            print("Can get Serialnumber for Storagesystem: ".$storagename."\n");
            if($daemon) {
                stopservice();
            }
            exit(1);
        }
        if(defined $metricfiles{$serial}) {
            $metricconf = $metricfiles{$serial};
        } else {
            print("Can get metricfile for serialnumber ".$serial." with arraytype: ".$arraytype{$serial}."\n");
            if($daemon) {
                stopservice();
            }
            exit(1);
        }
    }
    # if the -exportpath option is specified the data stored in this directory will be imported. There will be no run of Export Tool itself
    if(($exportpath) ne "" && (!$daemon)) {
        $noexporttool = true;
    } else {
        $exportpath = $exporttoolpath."out/".$serial."/";
    }
    if($help) {
        printUsage();
        if($daemon) {
            stopservice();
        }
        exit(0);
    }
    # add trailing / to path if neccessary
    my $lastchar = substr($exportpath,-1);
    if($lastchar ne "\/") {
        $exportpath.="\/";
    }
    # Query UID and GID for OpenIOmon

    my ($login,$pass,$uid,$gid) = getpwnam($serviceuser) or die "User $serviceuser not in passwd file! Please check!";
    $openiomonuid = $uid;
    $openiomongid = $gid;

    # before starting set the needed defaults if specified per storage system
    setdefaults();
}

# This sub will change the defaults for config file parameters if they are defined per storage system

sub setdefaults {

    if(defined $graphiteconf{$serial}{"graphite_host"}) {
        $graphitehost = $graphiteconf{$serial}{"graphite_host"};
    }
    if(defined $graphiteconf{$serial}{"graphite_port"}) {
        $graphiteport = $graphiteconf{$serial}{"graphite_port"};
    }
    if(defined $graphiteconf{$serial}{"max_metrics_per_minute"}) {
        $maxmetricsperminute = $graphiteconf{$serial}{"max_metrics_per_minute"};
    }
    if(defined $exporttoolparams{$serial}{"enable_archive"}) {
        $enablearchive = $exporttoolparams{$serial}{"enable_archive"};
    }
    if(defined $exporttoolparams{$serial}{"archivepath"}) {
        $archivepath = $exporttoolparams{$serial}{"archivepath"};
    }
    if(defined $exporttoolparams{$serial}{"hours_to_archive"}) {
        $hourstopreserve = $exporttoolparams{$serial}{"hours_to_archive"};
    }
    if(defined $exporttoolparams{$serial}{"path"}) {
        $exporttoolpath = $exporttoolparams{$serial}{"path"};
    }
    if(defined $exporttoolparams{$serial}{"retry_count"}) {
        $exporttoolretrycnt = $exporttoolparams{$serial}{"retry_count"};
    }
    if(defined $exporttoolparams{$serial}{"retry_timeout"}) {
        $exporttoolretrytimeout = $exporttoolparams{$serial}{"retry_timeout"};
    }
    if(defined $ccicredentials{$serial}{"user"}) {
        $cciuser = $ccicredentials{$serial}{"user"};
    }
    if(defined $ccicredentials{$serial}{"passwd"}) {
        $ccipasswd = $ccicredentials{$serial}{"passwd"};
    }
    if(defined $serviceconf{$serial}{"service_run_every_hours"}) {
        $runeveryhours = $serviceconf{$serial}{"service_run_every_hours"};
    }
    if(defined $serviceconf{$serial}{"service_run_minutes_after_hour"}) {
        $minafterfullhours = $serviceconf{$serial}{"service_run_minutes_after_hour"};
    }
}

# Sub will check if system is Panama (Gx00 / Fx00)

sub isPanama {
    my $type = $_[0];
    $type = uc($type);
#   print("In isPanama-Check: ".$type."\n");
    given ($type) {
        when ("G200") {return true}
        when ("G400") {return true}
        when ("G600") {return true}
        when ("G800") {return true}
        defaults {return false}
    }
}

# Sub will check if system is Panama2 (G130 G/F350 G/F370 G/F700 G/F900)

sub isPanama2 {
    my $type = $_[0];
    $type = uc($type);
#   print("In isPanama2-Check: ".$type."\n");
    given ($type) {
        when ("G350") {return true}
        when ("G370") {return true}
        when ("G700") {return true}
        when ("G900") {return true}
        default {return false}
    }
}

# Sub will read the configfile

sub readconfig {
    # Open the configfile...
    open my $configfilefp, '<', $conf or die "Can't open file: $!";
    my $section = "";
    my $arraytype = "";
        my $arrayserial = "";
        my $storagename = "";

    while(<$configfilefp>) {
        my $configline = $_;
        chomp ($configline);
        # Skip all line starting with a # (hash).
        #

        if (($configline !~ "^#") && ($configline ne "")){
            # read the section from the config file
            if ($configline =~ '\[') {
                $configline =~ s/\[//g;
                $configline =~ s/\]//g;
                $configline =~ s/\s//g;
                $section = $configline;
            } else {
                # Read the config parameters based on the config file section
                given($section) {
                    when ("logging") {
                        my @values = split ("=",$configline);
                        if($configline=~"hds2graphite_logdir") {
                            $logfile = $values[1];
                            $logfile =~ s/\s//g;
                        } elsif ($configline=~"exporttool_logdir") {
                            $etlogfile = $values[1];
                            $etlogfile =~ s/\s//g;
                        } elsif ($configline=~"loglevel") {
                            my $configloglevel = $values[1];
                            $configloglevel=~ s/\s//g;
                            if(uc($configloglevel) eq "FATAL") {
                                $loglevel = "FATAL";
                            } elsif (uc($configloglevel) eq "ERROR") {
                                $loglevel = "ERROR";
                            } elsif (uc($configloglevel) eq "WARN") {
                                $loglevel = "WARN";
                            } elsif (uc($configloglevel) eq "INFO") {
                                $loglevel = "INFO";
                            } elsif (uc($configloglevel) eq "DEBUG") {
                                $loglevel = "DEBUG";
                            } elsif (uc($configloglevel) eq "TRACE") {
                                $loglevel = "TRACE";
                            }
                            # otherwise keep default which is INFO
                        }
                    }
                    when ("exporttool") {
                        my @values = split ("=",$configline);
                        if($configline =~ "exporttool_path") {
                            $exporttoolpath = $values[1];
                            $exporttoolpath =~ s/\s//g;
                        } elsif ($configline =~ "exporttool_retry_count") {
                            $exporttoolretrycnt = $values[1];
                            $exporttoolretrycnt =~ s/\s//g;
                        } elsif ($configline =~ "exporttool_retry_timeout") {
                            $exporttoolretrytimeout = $values[1];
                            $exporttoolretrytimeout =~ s/\s//g;
                        }
                    }
                    when ("graphite") {
                        my @values = split ("=",$configline);
                        if($configline =~ "host") {
                            $graphitehost = $values[1];
                            $graphitehost =~ s/\s//g;
                        } elsif ($configline =~ "port") {
                            $graphiteport = $values[1];
                            $graphiteport =~ s/\s//g;
                        }
                    }
                    when ("cci") {
                        my @values = split ("=",$configline);
                        if($configline =~ "cci_user") {
                            $cciuser = $values[1];
                            $cciuser =~ s/\s//g;
                        } elsif ($configline =~ "cci_passwd") {
                            $ccipasswd = $values[1];
                            $ccipasswd =~ s/\s//g;
                        }
                    }
                    when ("gad") {
                        my @values = split ("=",$configline);
                        if($configline =~ "usevirtualldevs") {
                            if($values[1]=~"1") {
                                $usevirtualldev = true;
                            }
                        }
                    }
                    when ("performance") {
                        my @values = split ("=",$configline);
                        if($configline =~ "max_metrics_per_minute") {
                            $maxmetricsperminute = $values[1];
                        }
                    }
                    when ("archive") {
                        my @values = split ("=",$configline);
                        my $value = $values[1];
                        $value =~ s/\s//g;
                        chomp($value);
                        if($configline =~ "exporttool_enable_archive") {
                            if($value =~ "1") {
                                $enablearchive = true;
                            }
                        } elsif ($configline =~ "exporttool_archive_path") {
                            $archivepath = $value;
                            my $lastchar = substr($archivepath,-1);
                            if($lastchar ne "\/") {
                                $archivepath.="\/";
                            }
                        } elsif($configline =~ "exporttool_hours_to_archive") {
                            $hourstopreserve = $value;
                        }
                    }
                    when ("service") {
                        my @values = split ("=",$configline);
                        if($configline =~ "service_run_every_hours") {
                            $runeveryhours = $values[1];
                        } elsif ($configline =~ "service_run_minutes_after_hour") {
                            $minafterfullhours = $values[1];
                        }
                    }
                    default {
                        $arrayserial = $section;
                        if($configline =~ "subsystem_type") {
                            my @values = split ("=",$configline);
                            $arraytype = $values[1];
                            $arraytype =~ s/\s//g;
                            $arraytype = lc($arraytype);
                            $arraytype{$arrayserial}=$arraytype;
                        } elsif ($configline =~ "subsystem_name") {
                            my @values = split ("=",$configline);
                            $storagename = $values[1];
                            $storagename =~ s/\s//g;
                            $storagename = uc($storagename);
                            $namereference{$arrayserial}=$storagename;
                            $serialreference{$storagename}=$arrayserial;
                        } elsif ($configline =~ "svp_ip") {
                            my @values = split ("=",$configline);
                            my $svp_ip = $values[1];
                            $svp_ip =~ s/\s//g;
                            $systemips{$arrayserial}{"SVP"} = $svp_ip;
                        } elsif ($configline =~ "ctrl0_ip") {
                            my @values = split ("=",$configline);
                            my $ctrl0_ip = $values[1];
                            $ctrl0_ip =~ s/\s//g;
                            $systemips{$arrayserial}{"IP1"} = $ctrl0_ip;
                        } elsif ($configline =~ "ctrl1_ip") {
                            my @values = split ("=",$configline);
                            my $ctrl1_ip = $values[1];
                            $ctrl1_ip =~ s/\s//g;
                            $systemips{$arrayserial}{"IP2"} = $ctrl1_ip;
                        } elsif ($configline =~ "cci_instance_number") {
                            my @values = split ("=",$configline);
                            my $horcminstnumber = $values[1];
                            $horcminstnumber =~ s/\s//g;
                            #print $storagename."\n";
                            $cciinstances{$storagename}=$horcminstnumber;
                        } elsif ($configline =~ "cci_user") {
                            my @values = split ("=",$configline);
                            my $cci_user = $values[1];
                            $cci_user =~ s/\s//g;
                            $ccicredentials{$arrayserial}{"user"}=$cci_user;
                        } elsif ($configline =~ "cci_passwd") {
                            my @values = split ("=",$configline);
                            my $cci_passwd = $values[1];
                            $cci_passwd =~ s/\s//g;
                            $ccicredentials{$arrayserial}{"passwd"}=$cci_passwd;
                        } elsif ($configline =~ "metric_configruation") {
                            my @values = split ("=",$configline);
                            my $metric_file = $values[1];
                            $metric_file =~ s/\s//g;
                            $metricfiles{$arrayserial}=$metric_file;
                        } elsif ($configline =~ "exporttool_template") {
                            my @values = split ("=",$configline);
                            my $export_file = $values[1];
                            $export_file =~ s/\s//g;
                            $exporttooltemplates{$arrayserial}=$export_file;
                        } elsif ($configline =~ "exporttool_path") {
                            my @values = split ("=",$configline);
                            my $exp_path = $values[1];
                            $exp_path =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"path"} = $exp_path;
                        } elsif ($configline =~ "exporttool_retry_count") {
                            my @values = split ("=",$configline);
                            my $exp_retry_count = $values[1];
                            $exp_retry_count =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"retry_count"} = $exp_retry_count;
                        } elsif ($configline =~ "exporttool_retry_timeout") {
                            my @values = split ("=",$configline);
                            my $exp_retry_timeout = $values[1];
                            $exp_retry_timeout =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"retry_timeout"} = $exp_retry_timeout;
                        } elsif ($configline =~ "exporttool_enable_archive") {
                            my @values = split ("=",$configline);
                            my $exp_enable_archive = $values[1];
                            $exp_enable_archive =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"enable_archive"} = $exp_enable_archive;
                        } elsif ($configline =~ "exporttool_archivepath") {
                            my @values = split ("=",$configline);
                            my $exp_archivepath = $values[1];
                            $exp_archivepath =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"archivepath"} = $exp_archivepath;
                        } elsif ($configline =~ "exporttool_hours_to_archive") {
                            my @values = split ("=",$configline);
                            my $exp_hours_to_archive = $values[1];
                            $exp_hours_to_archive =~ s/\s//g;
                            $exporttoolparams{$arrayserial}{"hours_to_archive"} = $exp_hours_to_archive;
                        } elsif ($configline =~ "graphite_host") {
                            my @values = split ("=",$configline);
                            my $grap_host = $values[1];
                            $grap_host =~ s/\s//g;
                            $graphiteconf{$arrayserial}{"graphite_host"} = $grap_host;
                        } elsif ($configline =~ "graphite_port") {
                            my @values = split ("=",$configline);
                            my $grap_port = $values[1];
                            $grap_port =~ s/\s//g;
                            $graphiteconf{$arrayserial}{"graphite_port"} = $grap_port;
                        } elsif ($configline =~ "max_metrics_per_minute") {
                            my @values = split ("=",$configline);
                            my $max_metrics_per_minute = $values[1];
                            $max_metrics_per_minute =~ s/\s//g;
                            $graphiteconf{$arrayserial}{"max_metrics_per_minute"} = $max_metrics_per_minute;
                        } elsif ($configline =~ "service_run_every_hours") {
                            my @values = split ("=",$configline);
                            my $service_run_every_hours = $values[1];
                            $service_run_every_hours =~ s/\s//g;
                            $serviceconf{$arrayserial}{"service_run_every_hours"} = $service_run_every_hours;
                        } elsif ($configline =~ "service_run_minutes_after_hour") {
                            my @values = split ("=",$configline);
                            my $service_run_minutes_after_hour = $values[1];
                            $service_run_minutes_after_hour =~ s/\s//g;
                            $serviceconf{$arrayserial}{"service_run_minutes_after_hour"} = $service_run_minutes_after_hour;
                        } elsif ($configline =~ "gad_vsm") {
                            $configline =~ s/\s//g;
                            my @values = split ("=",$configline);
                            my @gad_vsm_strings = split(",",$values[1]);
                            my $gad_sn=$gad_vsm_strings[0];
                            my $gad_vsm_type = $gad_vsm_strings[1];
                            my $gad_name=$gad_vsm_strings[2];
                            my $gad_rgid=$gad_vsm_strings[3];
                            $vsms{$storagename}{$gad_rgid}{"name"} = $gad_name;
                            $vsms{$storagename}{$gad_rgid}{"type"} = $gad_vsm_type;
                            $vsms{$storagename}{$gad_rgid}{"serial"} = $gad_sn;
                        } elsif ($configline =~ "max_metrics_per_minute") {
                            $configline =~ s/\s//g;
                            my @values = split ("=",$configline);
                            $maxmetricsperminute = $values[1];
                        }
                    }
                }
            }
        }
    }
}

# Sub to read the metric configuration file for each type of storage system

sub readmetric {
    # open the metric configration file
    open my $configfp, '<', $metricconf or die "Can't open file: $!";
    while(<$configfp>) {
        my $confline = $_;
        # ignore lines starting with #
        if(substr($confline,0,1) ne "#") {
            my @values = split(";",$confline);
            my $table = $values[1];
            my $metric = $values[2];
            chomp($metric);
            my $perffile = $exportpath.$values[0];
            # Lines containing a * (asterisk) defined that all CSV files that match this pattern need to be imported
            if($perffile =~ '\*') {
                my $lscmd = "ls -l ".$perffile;
                my @results = `$lscmd`;
                foreach my $result (@results) {
                    my @lsline = split(" ",$result);
                    $config{$lsline[8]}{"table"} = $table;
                    $config{$lsline[8]}{"metric"} = $metric;
                    $config{$lsline[8]}{"itemselect"} = "auto";
                }
                # Line containing § (paragraph) indicate that a part of the filename will be used to specify the ITEM (MP Board, etc.) for which the data is conained in this CSV file.
                # There is for example one CSV file per MP instand of one file containing all MP data.
            } elsif ($perffile =~ "%") {
                my $plainfile = $perffile;
                my $from = index($perffile,"%");
                my $to = rindex($perffile,"%");
                $plainfile =~ s/%/\*/g;
                my $lscmd = "ls -l ".$plainfile;
                my @results = `$lscmd`;
                foreach my $result (@results) {
                    my @lsline = split(" ",$result);
                    my $item = substr($lsline[8], $from, $to-$from+1);
                    $config{$lsline[8]}{"table"} = $table;
                    $config{$lsline[8]}{"metric"} = $metric;
                    $config{$lsline[8]}{"itemselect"} = $item;
                }
            } else {
                # Regular metrics
                $config{$perffile}{"table"} = $table;
                $config{$perffile}{"metric"} = $metric;
                $config{$perffile}{"itemselect"} = "auto";
            }
        }
    }
    close ($configfp);
}

# Sub that imports all metric CSV files that need to be imported

sub importmetric {
    my @items;
    my $type = "";
    my $serial = "";
    initsocket();
    # looping over all metric CSV files that need to be imported
    $log->info("Starting metric import for ".$serial);
    foreach my $filename (sort keys (%config)) {
        if(!-f $filename) {
            $log->warn("The file ".$filename." doesn't exist but it is defined in the metrics configuration file. Check either Export Tool or remove file from metrics configuration file!");
            next;
        }
        my $metricstatcnt = 0;
        $log->info("Importing: ".$filename);
        open my $inputfp, '<', $filename or die "Can't open file: $!";
        my $linecnt = 1;
        my $table = $config{$filename}{"table"};
        my $firstlumetric = true;
        while(<$inputfp>) {
            my $line = $_;
            chomp($line);
            # get serial number out of the metric file
            if ($linecnt == 2) {
                my @values = split (":",$line);
                my $value = $values[1];
                $value =~ s/^\s+//;
                @values = split(/\(/,$value);
                $serial = $values[0];
                $type = $arraytype{$serial};
            } elsif ($line =~ "\"No.\",\"time\"") {
                # Read the header line from the metric CSV file that is currently imported. This header line might contain LDEVs, Ports, etc.!
                # Since the amount if colums in the metric file is not limited there could be multiple header line in one metric CSV file
                # which will be followed by data lines belonging to the items specified by the header.
                my @values = split (",",$line);
                splice(@items);
                my $num_elements = scalar @values;
                if($config{$filename}{"itemselect"} eq "auto") {
                    # The items will be created from the header in case of "auto"
                    for(my $i=2;$i<$num_elements;$i++) {
                        my $item = $values[$i];
                        # Graphite cannot handle spaces, line breaks, quotes and dots, so they will be removed or replaced
                        $item =~s/\"//g;
                        $item =~s/\./_/g;
                        $item =~s/\s/_/g;
                        $item =~s/\r//g;
                        if(substr($item,-1) eq "_") {
                            chop($item);
                        }
                        # LDEVs in Export Tool files always contain extensions like x, e, etc. these will be removed
                        if($table eq "LDEV") {
                            $item = substr($item,0,8);
                        }
                        # For Remote Copy the parentheses and units in the item names will be removed as they are unneccesary for Graphite
                        if($table eq "RC") {
                            my @itemparts = split('\(',$item);
                            $item = $itemparts[0];
                        }
                            $items[$i-2] = $item;
                    }
                } else {
                    # If the ITEM is not specified in the CSV File but comes from the configuration file we need to add this item to our ITEM-array
                    if($table eq "CACHE") {
                        for(my $i=2;$i<$num_elements;$i++) {
                            my $item = $values[$i];
                            # Graphite cannot handle spaces, line breaks, quotes and dots, so they will be removed or replaced
                            $item =~s/\"//g;
                            $item =~s/\./_/g;
                            $item =~s/\s/_/g;
                            $item =~s/\r//g;
                            $item =~s/\(/_/g;
                            $item =~s/\)//g;
                            if(substr($item,-1) eq "_") {
                                chop($item);
                            }
                            $items[$i-2] = $item.".".$config{$filename}{"itemselect"};
                        }
                    } else {
                        push(@items,$config{$filename}{"itemselect"});
                    }

                }
            } elsif ($linecnt > 7) {
                # Starting line 7 the lines are containing data...
                my @values = split (",",$line);
                # Read time from file and convert to EPOCH needed for graphite
                my $plaintime = $values[1];
                my $year = substr($plaintime,1,4);
                my $month = substr($plaintime,6,2);
                my $day = substr ($plaintime,9,2);
                my $hour = substr ($plaintime,12,2);
                my $minute = substr ($plaintime,15,2);
                my $second = "00";
                my $epochtime = timelocal($second,$minute,$hour,$day,$month-1,$year);
                my $num_elements = scalar @values;
                my $metric = $config{$filename}{"metric"};
                # Now we are looping through the colums of each line so we can read the data and align it to the item (e.g. LDEV-ID, Port, MP, etc.)
                for(my $i=2;$i<$num_elements;$i++) {
                    if ($values[$i] >= 0) {
                        my $value = $values[$i];
                        $value =~ s/\r//g;
                        if($table eq "LU") {
                            # During import of LU data LU and LDEV-Number will be combined.
                            my $port = "";
                                my $hsd = "";
                                my $lu = "";
                                my @itemparts = split("_",$items[$i-2]);
                                $port = $itemparts[0];
                                my $luindex = (scalar @itemparts)-1;
                                # Extracting HSD name and LUN number from String from Export Tool LU data.
                                $lu = sprintf '%03s', $itemparts[$luindex];
                                my $luold = $lu;
                                my $hsdstring = "";
                                for (my $i=1;$i<$luindex;$i++) {
                                    $hsdstring .= $itemparts[$i]."_";
                                }
                                chop($hsdstring);
                                my @hsdvalues = split('\(',$hsdstring);
                                my $hsdindex = $hsdvalues[0];
                                # VSP is giving back LUN IDs in HEX using RAIDCOM while all other systems are giving LUN IDs back in DEC
                                $hsdindex = sprintf("%02s",hex($hsdindex));
                                my $ldev = "";

                                # The skip variable is used to skip LDEVs where no information from the RAIDCOM data is available.
                                # This might happen if Export Tool data contains performance metrics for LDEVs that have been deleted during the monitoring interval.
                                my $skip = false;
                                if($type eq "vsp") {
                                    if(defined $lumapping{$port}{$hsdindex}{sprintf('%03s',hex($lu))}) {
                                        $ldev = $lumapping{$port}{$hsdindex}{sprintf('%03s',hex($lu))};
                                        $lu .= "-".$ldev;
                                    } else {
                                        $log->trace("No LDEV ID found for LU: ".$lu." in HSD: ".$hsdindex." on port: ".$port." for ".$namereference{$serial}."! Please check raidcom since Export Tool is reporting this LDEV!");
                                        $skip = true;
                                    }
                                } else {
                                    if(defined $lumapping{$port}{$hsdindex}{$lu}) {
                                        $ldev = $lumapping{$port}{$hsdindex}{$lu};
                                        #if(($usevirtualldev) && ($ldevmapping{$ldev}{"virtualldev"} ne "")) {
                                        #   $ldev = $ldevmapping{$ldev}{"virtualldev"};
                                        #}
                                        $lu .= "-".$ldev;
                                    } else {
                                        $log->trace("No LDEV ID found for LU: ".$lu." in HSD: ".$hsdindex." on port: ".$port." for ".$namereference{$serial}."! Please check raidcom since Export Tool is reporting this LDEV!");
                                        $skip = true;
                                    }
                                }
                                if(!$skip) {
                                    $hsd = $hsdvalues[1];
                                    chop ($hsd);
                                    $hsdreference{$port}{$hsdindex}=$hsd;
                                    $metricstatcnt+=1;
                                    toGraphite("hds.perf.physical.".$type.".".$namereference{$serial}.".".$table.".".$port.".".$hsd.".".$lu.".".$metric." ".$value." ".$epochtime);
                                    if (defined($ldevmapping{$ldev}{"rsgid"})) {
                                        my $rsgid = $ldevmapping{$ldev}{"rsgid"};
                                        if($rsgid != 0) {
                                            if($ldevmapping{$ldev}{"virtualldev"} eq "00:FF:FF") {
                                                $log->debug("Found virtual ldev 00:FF:FF for LU ".$luold." for LDEV ".$ldev." looks like LDEV might be GAD reserved but GAD pair is not in place");
                                            } else {
                                                $lu =  $luold."-".$ldevmapping{$ldev}{"virtualldev"};
                                                toGraphite("hds.perf.virtual.".$vsms{$namereference{$serial}}{$rsgid}{"type"}.".".$vsms{$namereference{$serial}}{$rsgid}{"name"}.".".$table.".".$port.".".$hsd.".".$lu.".".$namereference{$serial}.".".$metric." ".$value." ".$epochtime);
                                            }
                                        }
                                    }
                                }
                        } elsif ($table eq "LDEV") {
                            # Since there is no information about PG or DP on the Export Tool data this information will be added from the hash filled with RAIDCOM query information.
                            my $ldev = $items[$i-2];
                            if(!defined $ldevmapping{$ldev}{"entity"}) {
                                $log->trace("No Pool or PG found for LDEV: ".$ldev." on storagesystem ".$namereference{$serial});
                            } else {
                                my $ldevtype = $ldevmapping{$ldev}{"type"};
                                my $entity = $ldevmapping{$ldev}{"entity"};
                                #if(($usevirtualldev) && ($ldevmapping{$ldev}{"virtualldev"} ne "")) {
                                #   $ldev = $ldevmapping{$ldev}{"virtualldev"};
                                #}
                                $metricstatcnt+=1;
                                toGraphite("hds.perf.physical.".$type.".".$namereference{$serial}.".".$table.".".$ldevtype.".".$entity.".".$ldev.".".$metric." ".$value." ".$epochtime);
                                if (defined($ldevmapping{$ldev}{"rsgid"})) {
                                    my $rsgid = $ldevmapping{$ldev}{"rsgid"};
                                    if($rsgid != 0) {
                                        if($ldevmapping{$ldev}{"virtualldev"} eq "00:FF:FF") {
                                            $log->debug("Found virtual ldev 00:FF:FF for physical LDEV ".$ldev." looks like LDEV might be GAD reserved but GAD pair is not in place");
                                        } else {
                                            $ldev = $ldevmapping{$ldev}{"virtualldev"};
                                            toGraphite("hds.perf.virtual.".$vsms{$namereference{$serial}}{$rsgid}{"type"}.".".$vsms{$namereference{$serial}}{$rsgid}{"name"}.".".$table.".".$ldevtype.".".$entity.".".$ldev.".".$namereference{$serial}.".".$metric." ".$value." ".$epochtime);
                                        }
                                    }
                                }
                            }
                        } elsif ($table eq "RC") {
                            # Remote copy only contains one file so the ENTITY field is not needed for inserting to graphite.
                            $metricstatcnt+=1;
                            toGraphite("hds.perf.physical.".$type.".".$namereference{$serial}.".".$table.".".$items[$i-2]." ".$value." ".$epochtime);
                        } else {
                            # All standard metrics are send out...
                            $metricstatcnt+=1;
                            #print "Table: ".$table."\n";
                            #print "Filename: ".$filename."\n";
                            #print "Metric:".$metric."\n";
                            #print "Items:".$items[$i-2]."\n";

                            toGraphite("hds.perf.physical.".$type.".".$namereference{$serial}.".".$table.".".$items[$i-2].".".$metric." ".$value." ".$epochtime);
                        }
                    }
                }
            }
            $linecnt +=1;
        }
        logscriptstats("metric.count.".$table.".".$config{$filename}{"metric"},$metricstatcnt,$starttime,false);
        close ($inputfp);
    }
    closesocket();
}

# Sub to create the Export Tool configuration file during runtime using the template files available for each storage system type.

sub createexporttoolconf {
    $log->info("Creating Export Tool Configfile for ".$serial);
    my $cmdfile = $exporttoolpath.$arraytype{$serial}."/".$serial.".txt";
    my $cmdtemplate = $exporttooltemplates{$serial};

    if(!-f $cmdtemplate) {
        $log->error("Cannot open erporttool template file! Please check file ".$cmdtemplate);
        exit(1);
    }

    open my $cmdtemplatefp, '<', $cmdtemplate or die "Can't open file: $!";
    open my $cmdfilefp, '>', $cmdfile or die "Can't open file: $!";
    # For Gx00/Fx00 Systems the IPs of both controllers need to be specified...
    if(isPanama($arraytype{$serial}) || isPanama2($arraytype{$serial})) {
        print $cmdfilefp "ip ".$systemips{$serial}{"SVP"}."\n";
        print $cmdfilefp "dkcsn ".$serial."\n";
    } else {
        print $cmdfilefp "svpip ".$systemips{$serial}{"SVP"}."\n";
    }
    print $cmdfilefp "retry time=".$exporttoolretrytimeout." count=".$exporttoolretrycnt."\n";
    print $cmdfilefp "login ".$cciuser." \"".$ccipasswd."\"\n";
    while(<$cmdtemplatefp>) {
        my $line = $_;
        if($line =~ "option nocompress clear") {
            # For Gx00/Fx00 Systems there is no differentiation between short and long range data. Only range can be specified
            if(isPanama($arraytype{$serial}) || isPanama2($arraytype{$serial})) {
                print $cmdfilefp "range -".sprintf('%02s',$hourstoimport)."10:\n";
            } else {
                print $cmdfilefp "shortrange -".sprintf('%02s',$hourstoimport)."10:\n";
                print $cmdfilefp "longrange -000030:\n";
            }
            print $cmdfilefp "outpath \"".$exportpath."\"\n";
            print $cmdfilefp $line;
        } else {
            print $cmdfilefp $line;
        }

    }

    close($cmdfilefp);
    close($cmdtemplatefp);
    chown($openiomonuid,$openiomongid,$cmdfile);
}

# Sub to start the Export Tool
# Since the command that need to be executed is diffrent depending of the storage system type it is necessary to handle every array type separate.

sub startexporttool {
    my $classpath = "";
    my $cmdfile = $exporttoolpath.$arraytype{$serial}."/".$serial.".txt";
    my $exporttoollog = $etlogfile.$serial;
    my $returnvalue = 0;

    my $pid = fork();

    if(!$pid) {
        # All G1x00/F1x00 and Gx00/Fx00 systems are handled identical
        if (($arraytype{$serial} eq "g1000")||($arraytype{$serial} eq "g1500")||isPanama($arraytype{$serial}) || isPanama2($arraytype{$serial})) {
            $classpath = $exporttoolpath.$arraytype{$serial}."/lib/JSanExportLoader.jar";
            # The variale $javacmd is only needed to to write the call in the log
            my $javacmd = "/usr/bin/java -classpath \"".$classpath."\" -Del.tool.Xmx=536870912 -Dmd.command=".$cmdfile." -Del.logpath=".$exporttoollog."  -Dmd.rmitimeout=20 sanproject.getexptool.RJElMain";
            $log->info("Executing: ".$javacmd);
            $returnvalue = system("/usr/bin/java","-classpath", $classpath , "-Del.tool.Xmx=536870912", "-Dmd.command=".$cmdfile,"-Del.logpath=".$exporttoollog,"-Dmd.rmitimeout=20", "sanproject.getexptool.RJElMain");
        } elsif ($arraytype{$serial} eq "vsp") {
            $classpath = $exporttoolpath.$arraytype{$serial}."/lib/JSanExport.jar:".$exporttoolpath.$arraytype{$serial}."/lib/JSanRmiApiEx.jar:".$exporttoolpath.$arraytype{$serial}."/lib/JSanRmiServerUx.jar";
            my $javacmd = "/usr/bin/java -classpath \"".$classpath."\" -Xmx536870912 -Dmd.command=".$cmdfile." -Dmd.logpath=".$exporttoollog." -Dmd.rmitimeout=20 sanproject.getmondat.RJMdMain";
            $log->info("Executing: ".$javacmd);
            $returnvalue = system("/usr/bin/java","-classpath", $classpath , "-Xmx536870912","-Dmd.command=".$cmdfile,"-Dmd.logpath=".$exporttoollog,"-Dmd.rmitimeout=20","sanproject.getmondat.RJMdMain");
        }
        # Export Tool didn't run successful
        $returnvalue = $returnvalue >> 8;
        exit($returnvalue);
    }
    while(true) {
        my $res = waitpid($pid, WNOHANG);
        $log->trace("Waiting for ".$pid." to be finished...");
        sleep(10);
        alive();
        if ($res == -1) {
            $log->error("Some error occurred while forking Export Tool! Resturncode: ".$?>>8);
            return(false);
        }
        if ($res) {
            my $rc = $?>>8;
            $log->debug("Export Tool Fork with $res ended successful with returncode ".$rc);
            if($rc == 0) {
                $log->info("Export Tool finished successful");
                return(true);
            } else {
                $log->error("Export Tool failed to finish successful! Export Tool return code: ".$rc." ! Please check Export Tool logs under ".$exporttoollog." !");
                return(false);
            }
        }
    }
}

# Sub to cleanup old Export Tool logs

sub clearexporttoollogs {
    my $exporttoollog = $etlogfile.$serial;
    if(-d $exporttoollog) {
        opendir (DIR, $exporttoollog) or die 'Failed to open Direcory! '.$!;
        while (my $file = readdir(DIR)) {
            if($file=~".log") {
                my $creationtime = stat($exporttoollog."/".$file)->ctime;
                # keeping 7 days of logs...
                my $deleteifolder = time-(7*24*60*60);
                if($creationtime < $deleteifolder) {
                    $log->debug("Deleted Export Tool logfile ".$exporttoollog."/".$file);
                    unlink($exporttoollog."/".$file);
                }
            }
        }
    }
}

# Sub to create the HORCM.conf file in /etc/ directory
sub createhorcmconf {
    $log->info("Creating horcm".$horcminst.".conf in /etc/ !");
    my $horcminstfile = '/etc/horcm'.$horcminst.'.conf';
    open my $horcmfilefp, '>', $horcminstfile or die "Can't open $horcminstfile because of: $!";
    print $horcmfilefp "HORCM_MON\n";
    # HORCM Serviceport = 11 + Instance-Numer 3-digits with leading 0
    print $horcmfilefp "localhost       11".sprintf('%03s',$horcminst)."   3000    6000\n";
    print $horcmfilefp  "HORCM_CMD\n";
    if(isPanama($arraytype{$serial}) || isPanama2($arraytype{$serial})) {
        print $horcmfilefp '\\\.\IPCMD-'.$systemips{$serial}{"IP1"}."-31001";
        print $horcmfilefp '   \\\.\IPCMD-'.$systemips{$serial}{"IP2"}."-31001";
    } else {
        print $horcmfilefp '\\\.\IPCMD-'.$systemips{$serial}{"SVP"}."-31001";
    }
    print $horcmfilefp "\n";
    close ($horcmfilefp);
}

# Sub to run CCI command non blocking and return output of CCI command as array

sub runccicmd {
    my $cmd = $_[0];
    my $pid = fork();
    my @resultlines;

    my $exchangefile = $exportpath."cci_exchange.tmp";

    if(!-d $exportpath) {
        mkdir $exportpath;
    }
    if(!$pid) {
        open(my $fhw,'>',$exchangefile) or die "Can't open < ".$exchangefile.": $!";
        my @result = `$cmd`;
        foreach my $line (@result) {
            print $fhw $line;
        }
        close($fhw);
        exit(0);
    }
    while(1) {
        my $res = waitpid($pid, WNOHANG);
        alive();
        sleep(1);
        $log->trace("Waiting for PID ".$pid." to finish...");
        if ($res == -1) {
            $log->error("Some error occurred while forking for CCI CMD: ".$cmd." ! Returncode: ".$?>>8);
            return(@resultlines);
        }
        if ($res) {
            my $rc = $?>>8;
            $log->debug("CCI Command Fork for command ".$cmd." with PID $res ended successful with returncode ".$rc);
            open(my $fhr,'<',$exchangefile) or die "Can't open < ".$exchangefile.": $!";
            while(<$fhr>) {
                push(@resultlines,$_);
            }
            close($fhr);
            unlink($exchangefile);
            return(@resultlines);
        }
    }

}

# Sub to run CCI commamd non blocking and return the returnvalue of the CCI Command

sub execccicmd {
    my $cmd = $_[0];
    my $pid = fork();
    my @resultlines;

    if(!$pid) {
        my $result = system($cmd);
        $result = $result >> 8;
        exit $result;
    }
    while(1) {
        my $res = waitpid($pid, WNOHANG);
        alive();
        sleep(1);
        if ($res == -1) {
            $log->error("Some error occurred while forking for execution of CCI CMD: ".$cmd." ! Returncode: ".$?>>8);
            return(1);
        }
        if ($res) {
            my $rc = $?>>8;
            $log->debug("CCI Command Fork for command ".$cmd." with PID $res ended successful with returncode ".$rc);
            return($rc);
        }
    }
}

# Sub to start CCI instance

sub starthorcm {
    $log->info("Starting HORCM instance #",$horcminst);
    my $horcmstartcmd = "/HORCM/usr/bin/horcmstart.sh ".$horcminst;
    my @returnvalue = runccicmd($horcmstartcmd);
    foreach my $returnline (@returnvalue) {
        if ($returnline =~ "already been running") {
            $log->debug("Failed to start HORCM instance #",$horcminst,"! Instance already running! Restarting instance!");
            shutdownhorcm();
            starthorcm();
        } elsif ($returnline =~ "failed to start") {
            $log->fatal("Failed to start HORCM instance #",$horcminst,"! Please inspect CCI logs under /HORCM/log".$horcminst);
            exit(1);
        }
    }
}

# Sub for shutdown of CCI instance

sub shutdownhorcm {
        $log->info("Stoping HORCM instance #",$horcminst);
        my $returnvalue = execccicmd("/HORCM/usr/bin/horcmshutdown.sh ".$horcminst);
        if($returnvalue != 0) {
                $log->fatal("Failed to stop HORCM instance #",$horcminst,"! Please inspect CCI logs under /opt/HORCM/log".$horcminst);
                exit(1);
        }
}

# Sub for login to CCI / RAIDCOM with user provided in configuration file.

sub raidcomlogin {
    $log->info("Logging in with raidcom on instance #".$horcminst." with user ".$cciuser);
    my $returnvalue = execccicmd("/HORCM/usr/bin/raidcom -login ".$cciuser." ".$ccipasswd." -I".$horcminst);
    if($returnvalue != 0) {
        $log->fatal("Failed to login to HORCM instance #",$horcminst,"! Please inspect CCI logs under /opt/HORCM/log".$horcminst);
        exit(1);
    }
}

# Sub for logout from CCI

sub raidcomlogout {
    $log->info("Logout from raidcom instance #".$horcminst."!");
    my $returnvalue = execccicmd("/HORCM/usr/bin/raidcom -logout -I".$horcminst);
    if($returnvalue != 0) {
        $log->fatal("Failed to login to HORCM instance #",$horcminst,"! Please inspect CCI logs under /opt/HORCM/log".$horcminst);
        exit(1);
    }
}

# Sub to query all Pools (HDP/HDT/TI)

sub getpools {
    $log->info("Retrieving pools from HORCM instance #".$horcminst);
    my $getpoolcmd = "raidcom get pool -I".$horcminst;
    my @result = runccicmd($getpoolcmd);
    my $poolcnt = 0;
    foreach my $line (@result) {
        if ($line !~ "^PID") {
            my @values = split(" ",$line);
            my $poolid = $values[0];
            my $capacity = $values[5];
            my $volcnt = $values[3];
            my $available = $values[4];
            $poolstats{$poolid}{"capacity"} = $capacity;
            $poolstats{$poolid}{"available"} = $available;
            $poolstats{$poolid}{"used"} = $capacity - $available;
            $poolstats{$poolid}{"percentused"} = ($capacity - $available) / $capacity;
            $poolstats{$poolid}{"percentavailable"} = $available / $capacity;
            $poolstats{$poolid}{"volcnt"} = $volcnt;
            $poolcnt += 1;
        }
    }
    if($poolcnt == 0) {
        $log->error("No pools could be found?");
    }
}

# Sub to query all parity groups

sub getpgs {
    @pgs = ();
    $log->info("Retrieving parity groups for HORCM instance #".$horcminst);
    my $getpgcmd = "raidcom get parity_grp -I".$horcminst;
    my @result = runccicmd($getpgcmd);
    my $pgcnt = 0;
    foreach my $line (@result) {
        if($line !~ "^T GROUP") {
            my @values = split(" ",$line);
            my $pgid = $values[1];
            push (@pgs,$pgid);
            $pgcnt += 1;
        }
    }
    if($pgcnt == 0) {
        $log->fatal("No Parity Groups found! This is not normal! Aborting script...");
        if($daemon) {
            stopservice();
        }
        if($daemon) {
            stopservice();
        }
        exit(1);
    }

}

# Sub to create plain LDEV ID with : and capital letters

sub makeplainldevid {
    my $shortldev = $_[0];
    my $ldevstringlen = length($shortldev);
    my $ldev = "";
    # LDEV ID format has to be changed. RAIDCOM provides "only" a HEX value
    if($ldevstringlen==1) {
        $ldev = "00:00:0".uc($shortldev);
    } elsif ($ldevstringlen==2) {
        $ldev = "00:00:".uc($shortldev);
    } elsif ($ldevstringlen==3) {
        $ldev = "00:0".uc(substr($shortldev,0,1)).":".uc(substr($shortldev,1,2));
    } elsif ($ldevstringlen==4) {
        $ldev = "00:".uc(substr($shortldev,0,2)).":".uc(substr($shortldev,2,2));
    }
    return($ldev);
}

# Sub to query information of all HDP and HDT volumes
# This contains the following information:
#       physical LDEV ID
#       virtual LDEV ID
#       HDP-Pool ID
#       Volume Capacity
#       Tiering Information
#       HSD Mapping Information

sub getdpldevs {
    $log->info("Retrieving LDEV information for all pools");
    foreach my $poolid (sort keys %poolstats) {
        my $ldevquery = "raidcom get ldev -ldev_list dp_volume -pool_id ".$poolid." -fx -I".$horcminst;
        my @results = runccicmd($ldevquery);
        my $ldev = "";
        my $virtualldev = "";
        my $ldevcnt = 0;
        my $capacity = 0;
        my $used = 0;
        my $tier1 = 0;
        my $tier2 = 0;
        my $tier3 = 0;
        foreach my $line (@results) {
            if ($line =~ "^LDEV :") {
                $virtualldev = "";
                my $virtualldevid = "";
                my @ldevvalues = split(":",$line);
                my $shortldev = $ldevvalues[1];
                if($line=~"VIR_LDEV :") {
                    my @virtualparts = split(" ",$shortldev);
                    $shortldev = $virtualparts[0];
                    $virtualldevid = $ldevvalues[2];
                    chomp($shortldev);
                    $virtualldevid =~ s/\s//g;
                    $virtualldev = makeplainldevid($virtualldevid);
                }
                chomp($shortldev);
                $shortldev =~ s/\s//g;
                $ldev = makeplainldevid($shortldev);
                $ldevmapping{$ldev}{"type"} = "DP";
                $ldevmapping{$ldev}{"entity"} = $poolid;
                $ldevmapping{$ldev}{"virtualldev"} = $virtualldev;
                my $cleanldev = $ldev;
                $capacity = 0;
                $used = 0;
                $tier1 = 0;
                $tier2 = 0;
                $tier3 = 0;
                $ldevcnt += 1;
            } elsif ($line =~ "VOL_Capacity") {
                my @capacityline = split(":",$line);
                $capacity = $capacityline[1];
                chomp($capacity);
                $capacity =~ s/\s//g;
                $ldevmapping{$ldev}{"capacity"}=$capacity/2;
            } elsif ($line =~ "Used_Block") {
                my @usedline = split(":",$line);
                $used = $usedline[1];
                chomp($used);
                $used =~ s/\s//g;
                $ldevmapping{$ldev}{"used"}=$used/2;
            } elsif (($line =~ "TIER#1") && ($line =~ "MB")) {
                my @tierline = split(":",$line);
                $tier1 = $tierline[1];
                chomp($tier1);
                $tier1 =~ s/\s//g;
                $tier1 = $tier1*1024; # convert MB to KB
                $ldevmapping{$ldev}{"tier1"}=$tier1;
            } elsif (($line =~ "TIER#2") && ($line =~ "MB")) {
                my @tierline = split(":",$line);
                $tier2 = $tierline[1];
                chomp($tier2);
                $tier2 =~ s/\s//g;
                $tier2 = $tier2*1024; # convert MB to KB
                $ldevmapping{$ldev}{"tier2"}=$tier2;
            } elsif (($line =~ "TIER#3")&&($line =~ "MB")) {
                my @tierline = split(":",$line);
                $tier3 = $tierline[1];
                chomp($tier3);
                $tier3 =~ s/\s//g;
                $tier3 = $tier3*1024; # convert MB to KB
                $ldevmapping{$ldev}{"tier3"}=$tier3;
            } elsif ($line =~ "^PORTs") {
                # To map the relation between LU and LDEV the port information of command "raidcom get ldev" are evaluated and written to a hash
                my @portvalues = split(":",$line);
                my $portcount = scalar (@portvalues);
                if($line=~ "CL") {
                    for (my $i=1;$i<$portcount;$i++) {
                        my $portstring = $portvalues[$i];
                        my @portparts = split(" ",$portstring);
                        my $portelemets = $portparts[0];
                        my @portparts2 = split("-",$portelemets);
                        my $port = $portparts2[0]."-".$portparts2[1];
                        my $lu = $portparts[1];
                        $lu =~ s/\s//g;
                        $lu = sprintf '%03s',$lu;
                        my $hsd = $portparts2[2];
                        $hsd = sprintf '%02s',$hsd;
                        $lumapping{$port}{$hsd}{$lu} = $ldev;
                    }
                }
            } elsif ($line =~ "RSGID :") {
                my @rgidstring = split(":",$line);
                my $rsgid = $rgidstring[1];
                $rsgid =~ s/\s//g;
                #if($rsgid != 0) {
                #   print "LDEV: ".$ldev." => RSGID: ".$rsgid."\n";
                #}
                $ldevmapping{$ldev}{"rsgid"} = $rsgid;
            }
        }
        if($ldevcnt == 0) {
            $log->warn("No LDEVs found in DP Pools ".$poolid);
        }
    }
}

# Sub to query information for parity groups...

sub getpgldevs {
    $log->info("Retrieve LDEV information for all PGs");
    foreach my $pg (@pgs) {
        my $ldevquerycmd = "raidcom get ldev -ldev_list parity_grp -parity_grp_id ".$pg." -fx -I".$horcminst;
        my @results = runccicmd($ldevquerycmd);
        my $ldev = "";
        my $ldevcnt = 0;
        foreach my $line (@results) {
            if($line =~ "^LDEV :") {
                my @ldevvalues = split(":",$line);
                my $shortldev = $ldevvalues[1];
                chomp($shortldev);
                $shortldev =~ s/\s//g;
                $ldev = makeplainldevid($shortldev);
                $ldevmapping{$ldev}{"type"} = "PG";
                $ldevmapping{$ldev}{"entity"} = $pg;
                $ldevmapping{$ldev}{"virtualldev"} = "";
                $ldevcnt += 1;
            } elsif($line =~ "VOL_Capacity") {
                my @capacityline = split(":",$line);
                my $capacity = $capacityline[1];
                chomp($capacity);
                $capacity =~ s/\s//g;
                $ldevmapping{$ldev}{"capacity"}=$capacity/2;
                $ldevmapping{$ldev}{"used"}=$capacity/2;
            }
        }
        if($ldevcnt == 0) {
            $log->warn("No LDEV found in PG ".$pg);
        }
    }
}

# Sub to log Pool statistis (capacity / volume count) to graphite

sub logpoolstats {
    initsocket();
    $log->info("Logging pool statistics to carbon for ".$namereference{$serial});
    my $now = time();
    # timestamp will be rounded to last full hour
    $now = int((int($now/3600))*3600);
    foreach my $poolid (sort keys (%poolstats)) {
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".capacity ".$poolstats{$poolid}{"capacity"}." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".used ".$poolstats{$poolid}{"used"}." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".percentused ".$poolstats{$poolid}{"percentused"}." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".percentavailable ".$poolstats{$poolid}{"percentavailable"}." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".volumecount ".$poolstats{$poolid}{"volcnt"}." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".pool.".$poolid.".available ".$poolstats{$poolid}{"available"}." ".$now);
    }
    closesocket();
}

# Sub to log the Logical Device (LDEV) statistics.
# Sub will loop over all known LDEVs and transfer tiering and capacity information to graphite grouped by PG ID or POOL ID

sub logldevstats {
    initsocket();
    $log->info("Loging device capacity statistics for ".$namereference{$serial});
    my $now = time();
    # Rounded to last full hour
    $now = int((int($now/3600))*3600);
    foreach my $ldev (sort keys %ldevmapping) {
        if(!defined($ldevmapping{$ldev}{"capacity"})) {
            next;
        }
        if(!defined($ldevmapping{$ldev}{"entity"})) {
            next;
        }
        if(!defined($ldevmapping{$ldev}{"used"})) {
            next;
        }
        if(!defined($ldevmapping{$ldev}{"type"})) {
            next;
        }
        my $capacity = $ldevmapping{$ldev}{"capacity"};
        my $poolid = $ldevmapping{$ldev}{"entity"};
           my $used = $ldevmapping{$ldev}{"used"};
        my $type = $ldevmapping{$ldev}{"type"};
        my $tier1 = 0;
        if (defined($ldevmapping{$ldev}{"tier1"})) {
            $tier1 = $ldevmapping{$ldev}{"tier1"};
        }
        my $tier2 = 0;
        if (defined ($ldevmapping{$ldev}{"tier2"})) {
            $tier2 = $ldevmapping{$ldev}{"tier2"};
        }
        my $tier3 = 0;
        if(defined ($ldevmapping{$ldev}{"tier3"})) {
            $tier3 = $ldevmapping{$ldev}{"tier3"};
        }
        if(($usevirtualldev) && ($ldevmapping{$ldev}{"virtualldev"} ne "")) {
            $ldev = $ldevmapping{$ldev}{"virtualldev"};
        }
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".ldev.".$type.".".$poolid.".".$ldev.".capacity ".$capacity." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".ldev.".$type.".".$poolid.".".$ldev.".used ".$used." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".ldev.".$type.".".$poolid.".".$ldev.".tier1 ".$tier1." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".ldev.".$type.".".$poolid.".".$ldev.".tier2 ".$tier2." ".$now);
        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".ldev.".$type.".".$poolid.".".$ldev.".tier3 ".$tier3." ".$now);
    }
    closesocket();
}

# Sub to log the Logical Unit (LU) statistics.
# Sub will loop over all known ports / HSDs / LUs and transfer tiering and capacity information to graphite

sub loglustats {
    initsocket();
    $log->info("Logging LU capacity statistics for ".$namereference{$serial});
    my $now = time();
    # timestamp is rounded to last full hour
    $now = int((int($now/3600))*3600);
    foreach my $port (sort keys %lumapping) {
        foreach my $hsdindex (sort keys %{$lumapping{$port}}) {
            if(defined($hsdreference{$port}{$hsdindex})) {
                my $hsdname = $hsdreference{$port}{$hsdindex};
                foreach my $lu (sort keys %{$lumapping{$port}{$hsdindex}}) {
                    my $ldev = $lumapping{$port}{$hsdindex}{$lu};
                    if(defined($ldevmapping{$ldev}{"capacity"})) {
                        my $capacity = $ldevmapping{$ldev}{"capacity"};
                        my $used = $ldevmapping{$ldev}{"used"};
                        my $tier1 = 0;
                        if (defined($ldevmapping{$ldev}{"tier1"})) {
                            $tier1 = $ldevmapping{$ldev}{"tier1"};
                        }
                        my $tier2 = 0;
                        if (defined ($ldevmapping{$ldev}{"tier2"})) {
                            $tier2 = $ldevmapping{$ldev}{"tier2"};
                        }
                        my $tier3 = 0;
                        if(defined ($ldevmapping{$ldev}{"tier3"})) {
                            $tier3 = $ldevmapping{$ldev}{"tier3"};
                        }
                        if(($usevirtualldev) && ($ldevmapping{$ldev}{"virtualldev"} ne "")) {
                            $ldev = $ldevmapping{$ldev}{"virtualldev"};
                        }
                        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".lu.".$hsdname.".".$lu."-".$ldev.".capacity ".$capacity." ".$now);
                        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".lu.".$hsdname.".".$lu."-".$ldev.".used ".$used." ".$now);
                        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".lu.".$hsdname.".".$lu."-".$ldev.".tier1 ".$tier1." ".$now);
                        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".lu.".$hsdname.".".$lu."-".$ldev.".tier2 ".$tier2." ".$now);
                        toGraphite("hds.capacity.".$arraytype{$serial}.".".$namereference{$serial}.".lu.".$hsdname.".".$lu."-".$ldev.".tier3 ".$tier3." ".$now);
                    } else {
                        $log->debug("No LDEV information found for LDEV: ".$ldev." on storage ".$namereference{$serial});
                    }
                }
            } else {
                $log->trace("No HSD Name found for HSD ID: ".$hsdindex." on port ".$port." for storage ".$namereference{$serial});
            }
        }
    }
    closesocket();
}

# This function is used to log statistics of the script itself.
#
# Parameter 1: Metric to log
# Parameter 2: Value to log for metric
# Parameter 3: Timestamp to log the value for the metric
# Parameter 4: Flag to define whether the a new socket should be opened or not (true(1) or false(0))

sub logscriptstats {
        my $metric = $_[0];
        my $value = $_[1];
        my $scripttime = $_[2];
        my $opensocket = $_[3];
        if($opensocket) {
            initsocket();
        }
        toGraphite("hds.hds2graphite.stats.".$arraytype{$serial}.".".$namereference{$serial}.".".$metric." ".$value." ".$scripttime);
        $log->debug("Logging stats: ".$metric." for current run!");
        if($opensocket) {
            closesocket();
        }
}

# sub to initialize socket to graphite host

sub initsocket {
    $socket = new IO::Socket::INET (
        PeerHost => $graphitehost,
        PeerPort => $graphiteport,
        Proto => 'tcp',
    );
    die "cannot connect to the server $!\n" unless $socket;
    setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
    $log->debug("Opening connection ".$socket->sockhost().":".$socket->sockport()." => ".$socket->peerhost().":".$socket->peerport());
}

# sub to close socket to graphite host

sub closesocket {
    $log->debug("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
    $socket->shutdown(2);
}

# sub to send plain text protocol strings to graphite host including possibility to throttle the amount of messages sent to graphite

sub toGraphite() {
    $socketcnt+=1;
    my $message = $_[0];
    $socket->send($message."\n");
    # not every message will be delayed to allow quick systems to be utilized. Delay will only happen when the delay time is larger than 0ns since nanosleep(0) will consume time.
    if(($socketdelay>0)&&!($socketcnt % $delaymetric)) {
        nanosleep($socketdelay);
    }
    # every 100.000 inserts we will check how long it takes for 100.000 obejcts to insert. The delay will be adjusted base on this result compared to the maximum amount of metrics that should be imported.
    if($socketcnt>=100000) {
        alive();
        my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
        my $metricsperminute = 60/$elapsed*100000;
        if($socketdelay>0) {
            $socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
            # in case of running as service avoid that oversized delay will trigger the watchdog
            if($daemon) {
                if($socketdelay > $maxdelay) {
                    $socketdelay = $maxdelay;
                }
            }
        } else {
            # if the delay was going down to 0ns there needs to be a possibility to increase the delay again starting with 1us.
            $socketdelay = int(1000*($metricsperminute/$maxmetricsperminute));
        }
        $log->info("Elapsed time for last 100.000 Metrics: ".sprintf("%.2f",$elapsed)."s => metrics per minute: ".sprintf("%.2f",$metricsperminute)." new delay: ".$socketdelay);
        $sockettimer = [gettimeofday];
        $socketcnt = 0;
    }
}

# Sub to archive Export Tool data after retrieved from storage system

sub archiveexporttooldata {
    console("Archiving Export Tool-data...");
    if(!-d $archivepath.$storagename) {
        mkdir $archivepath.$storagename;
    }
    my $archivefile = $archivepath.$storagename."/".POSIX::strftime('%Y%m%d_%H%M', localtime)."_".$hourstoimport."hours.tar.gz";
    my $returnvalue = system('tar -czf '.$archivefile." ".$exportpath.' > /dev/null 2>&1');
    if($returnvalue != 0) {
        $log->error("Failed to create compressed tar archive with command: tar -czf ".$archivefile." ".$exportpath);
    } else {
        $log->info("Archive: ".$archivefile." has been created.");
    }
}

# Sub to delete old archived Export Tool data

sub deleteexporttoolarchives {
    if(-d $archivepath.$storagename) {
        opendir (DIR, $archivepath.$storagename) or die 'Failed to open Direcory! '.$!;
        while (my $file = readdir(DIR)) {
            if($file=~".tar.gz") {
                my $creationtime = stat($archivepath.$storagename."/".$file)->ctime;
                my $deleteifolder = time-($hourstopreserve*60*60);
                if($creationtime < $deleteifolder) {
                    $log->debug("Deleted archive file ".$archivepath.$storagename."/".$file);
                    unlink($archivepath.$storagename."/".$file);
                }
            }
        }
    } else {
        $log->error("Failed to open directory ".$archivepath.$storagename." to check for archives to be deleted!");
    }
}

# Sub to read time of last successful run from file

sub readlastruntime {
    my $runfile = $statusdir."/".$serial."_run.txt";
    if (!-f $runfile) {
        $lastsuccessfulrun = 0;
    } else {
        open(my $fh,'<',$runfile) or die "Can't open < ".$runfile." to write last successul runtime: $!";
        while(<$fh>) {
            my $line = $_;
            my @values = split(" ",$line);
            $lastsuccessfulrun = $values[0];
        }
    }
}

# Sub to write time of last successful run to file

sub writelastruntime {
    my $runfile = $statusdir."/".$serial."_run.txt";
    if (!-d $statusdir) {
        mkdir $statusdir;
    }
    open(my $fh,'>',$runfile) or die "Can't open < ".$runfile." to write last successul runtime: $!";
    print $fh $lastsuccessfulrun." ".$hourstoimport." ".$lastsuccessfulrunend;
    close $fh;
}

# Sub to calculate how many hours should be imported based on start time of last successful run. Will only be used when running as Daemon.

sub gethourstoimport {
    if($lastsuccessfulrun == 0) {
        return($hourstoimport);
    }
    my $deltaseconds = time - $lastsuccessfulrun-(10*60);
    my $hours = ceil($deltaseconds/60/60);
    if($hours>23) {
        $hours=23;
    }
    $log->info("Next run should import ".$hours." hours of data from Export Tool!");
    return($hours);
}

# Sub to delay process for scheduling based on configuration files. Will only be used when running as Daemon.

sub delayuntilnextrun {
    servicestatus("Waiting for next run...");
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    my $modulo = $hour%$runeveryhours;
    while(($min != $minafterfullhours) || ($modulo != 0)) {
        sleep(10);
        ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
        $modulo = $hour%$runeveryhours;
        alive();
    }
}

# Sub to initialize Systemd Service

sub initservice {
    notify( READY => 1 );
    $log->trace("Service is initialized...");
}

# Sub to update status of Systemd Service when running as Daemon

sub servicestatus {
    my $message = $_[0];
    notify( STATUS => $message );
    $log->trace("Status message: ".$message." is send to service...");
}

# Sub to signal a stop of the script to the service when running as Daemon

sub stopservice {
    notify ( STOPPING => 1 )
}

# Sub to send heartbeat to watchdog of Systemd service when running as Daemon.

sub alive {
    if($daemon) {
        notify ( WATCHDOG => 1 );
        if($loglevel eq "TRACE") {
            $log->trace("Heartbeat is send to watchdog of service...");
        }
    }
}

sub cleanhashes {
    %poolstats=();
    @pgs=();
    %ldevmapping=();
    %lumapping=();
    %hsdreference=();
}

#
# main
#


# parse CLI parameters...
parseCmdArgs();

$logfile.="hds2graphite_".$namereference{$serial}.".log";

# Log4perl initialzation...
my $log4perlConf  = qq(
log4perl.logger.main.report            = $loglevel,  FileAppndr1
log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
log4perl.appender.FileAppndr1.filename = $logfile
log4perl.appender.FileAppndr1.owner    = openiomon
log4perl.appender.FileAppndr1.group    = openiomon
log4perl.appender.FileAppndr1.umask    = 0000
log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppndr1.layout.ConversionPattern = %d [%p] (%F:%L) %M > %m %n
);

Log::Log4perl->init(\$log4perlConf);
$log = Log::Log4perl->get_logger('main.report');

initservice();

if($daemon) {
    readlastruntime();
}

do {
    alive();
    if($daemon) {
        delayuntilnextrun();
        $hourstoimport = gethourstoimport();
    }
    $starttime = time;
    $sockettimer = [gettimeofday];
    my $temptime = time;

    if($horcminst ne "") {
        createhorcmconf();
        starthorcm();
        raidcomlogin();
        $temptime = time;
        servicestatus("Querying data from RAIDCOM...");
        getpools();
        logscriptstats("runtime.getdppools",time-$temptime,$starttime,true);
        $temptime = time;
        getdpldevs();
        logscriptstats("runtime.getdpldev",time-$temptime,$starttime,true);
        $temptime = time;
        getpgs();
        logscriptstats("runtime.getpgs",time-$temptime,$starttime,true);
        $temptime = time;
        getpgldevs();
        logscriptstats("runtime.getpgldev",time-$temptime,$starttime,true);
        raidcomlogout();
        shutdownhorcm();
    }

    # Starting Export Tool

    if(!$noexporttool) {
        servicestatus("Running Export Tool...");
        createexporttoolconf();
        console("Starting Export Tool for serial: ".$serial.". This might take a few minutes...");
        $temptime = time;
        $exporttoolstatus = startexporttool();
        logscriptstats("runtime.Export Tool",time-$temptime,$starttime,true);
    }

    # Reading the metric file

    readmetric();

    # Starting the data import
    if($exporttoolstatus) {
        console ("Starting import of Export Tool data to graphite");
        servicestatus("Importing Export Tool data...");
        $temptime = time;
        importmetric();
        logscriptstats("runtime.importmetric",time-$temptime,$starttime,true);
        console ("Finished import of Export Tool data to graphite...");
        clearexporttoollogs();
    } else {
        servicestatus("Export Tool failed... Trying next interval...");
    }

    # Getting Pool, LDEV and LU stats
    $temptime = time;
    logpoolstats();
    logscriptstats("runtime.logpoolstats",time-$temptime,$starttime,true);
    $temptime = time;
    logldevstats();
    logscriptstats("runtime.logldevstats",time-$temptime,$starttime,true);
    $temptime = time;
    loglustats();
    logscriptstats("runtime.loglustats",time-$temptime,$starttime,true);
    if($exporttoolstatus) {
        archiveexporttooldata();
    } else {
        $log->warn("Omitting archiving of Export Tool data since Export Tool didn't run successful. Please check Export Tool and see error messages above!");
    }
    deleteexporttoolarchives();
    logscriptstats("runtime.total",time-$starttime,$starttime,true);
    if($exporttoolstatus) {
        $lastsuccessfulrun = $starttime;
        $lastsuccessfulrunend = time;
    }
    writelastruntime();
    cleanhashes();
} while($daemon);
