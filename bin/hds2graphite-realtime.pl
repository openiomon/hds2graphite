#!/bin/perl
#
#
#   Script for realtime data import from HTNM / HIAA to graphite
#
#

use v5.10;
use strict;
use warnings;
#no warnings qw( experimental::smartmatch );
use feature qw(switch);
no if $] >= 5.018, warnings => qw( experimental::smartmatch );
use constant false => 0;
use constant true  => 1;

use Getopt::Long;
use IO::Socket::INET;
use IO::Socket::UNIX;
use JSON;
use Log::Log4perl;
use LWP::UserAgent();
use POSIX qw(strftime);
use POSIX ":sys_wait_h";
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use Time::Piece;


my $ua; # = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });

my $htnm_server = '';
my $htnm_port = '';
my $htnm_proto = '';
my $htnm_appl = '';
my $htnm_user = '';
my $htnm_passwd = '';
my $htnm_rest_base_url = '';

my $graphite_host = '';
my $graphite_port = '';
my $usetag = 0;
my $ssl_verify = 1;

my $socketcnt = 0;
my $sockettimer = 0;
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;
my $socket;

my $metricpath = '/opt/hds2graphite/conf/metrics/';

my $watchdog = 300;
# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts.
#The factor 0.9 adds in some tollerance to avoid watchdog is killing service because delay for inserts is to high! This might happen if the 1ast 100.000 inserts are done in less than 2 seconds
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;

my %arrays;
my $storagename="";
my $storagetype="";
my %htnm_agents;
my $instance = '';
my $instance_hostname = '';

my @units;
my %metrics;
my %labels;
my %targets;
my %ldevs;

my %pids;
my %vsms;

my $interval = 60;

my $hdsdateformat = "%Y-%m-%d %H:%M:%S";

my $log;
my $logpath = '/opt/hds2graphite/log/';
my $logfile='';
my $loglevel = 'INFO';

my $mainpid = $$;

# Sub to print the parameter reference

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    print("   -conf <file>             conf file containig parameter for the import\n");
    print("   -storagesystem <name>    name of the storage system to be imported\n");
    print("   -h                       print this output\n");
    print("\n");
}

sub parseCmdArgs {
    my $help = "";
    my $conf = "";
    $storagename = "";
        GetOptions (    "conf=s"                => \$conf,              # String
                        "storagesystem=s"       => \$storagename,       # String
                        "h"                     => \$help)              # flag
        or die("Error in command line arguments\n");

    if($help) {
        printUsage();
        exit(0);
    }

    if($conf eq "") {
        print("Configuration file has not been specified!\n");
        printUsage();
        exit(0);
    }
    if($storagename eq "") {
        print("Storagesystem has not been specified!\n");
        printUsage();
        exit(0);
    }

    if(!-e $conf) {
        print("Configuration file cannot be found. Please check file: ".$conf."\n\n");
    } else {
        readconfig($conf);
    }

    if(!defined $arrays{$storagename}{"serial"}) {
        print("Cannot find ".$storagename." in ".$conf."! Please check configuration file or correct storage system name parameter.\n");
        exit(1);
    }

}

sub readconfig {
    my $configfilename = $_[0];
    open my $fh,'<',$configfilename or die "Cannot open config file $!";
    my $section = "";

    my $arrayserial = "";
    my $arraytype = "";
    my $conf_storagename = "";

    while(<$fh>) {
        my $configline = $_;
        chomp($configline);
        if (($configline !~ "^#") && (length($configline)>3)){
            if ($configline =~ '\[') {
                $configline =~ s/\[//g;
                $configline =~ s/\]//g;
                $configline =~ s/\s//g;
                $section = $configline;
            } else {
                given($section) {
                    when ("logging") {
                        my @values = split ("=",$configline);
                        if ($configline=~"hds2graphite_logdir") {
                            my $logpath = $values[1];
                            $logpath =~s/\s//g;
                            if(substr($logpath,-1) ne "/") {
                                $logpath = $logpath."/";
                            }
                        }
                        if ($configline=~"loglevel") {
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
                        }
                    }
                    when ("graphite") {
                        my @values = split ("=",$configline);
                        if($configline =~ "host") {
                            $graphite_host = $values[1];
                            $graphite_host =~ s/\s//g;
                        } elsif ($configline =~ "port") {
                            $graphite_port = $values[1];
                            $graphite_port =~ s/\s//g;
                        } elsif ($configline =~"^metric_format") {
                            $configline =~ s/\s//g;
                            my @values = split("=",$configline);
                            if($values[1] =~ "graphite-tag") {
                                $usetag = 1;
                            }
                        }
		            }
                    when ("realtime") {
                        my @values = split("=",$configline);
                        if($configline =~ "realtime_application") {
                            $htnm_appl = $values[1];
                            $htnm_appl =~ s/\s//g;
                        } elsif ($configline =~ "api_host") {
                            $htnm_server = $values[1];
                            $htnm_server =~ s/\s//g;
                        } elsif ($configline =~ "api_port") {
                            $htnm_port = $values[1];
                            $htnm_port =~ s/\s//g;
                        } elsif ($configline =~ "api_proto") {
                            $htnm_proto = $values[1];
                            $htnm_proto =~ s/\s//g;
                        } elsif ($configline =~ "api_user") {
                            $htnm_user = $values[1];
                            $htnm_user =~ s/\s//g;
                        } elsif ($configline =~ "api_passwd") {
                            $htnm_passwd = $values[1];
                            $htnm_passwd =~s/\s//g;
                        } elsif ($configline =~ "^ssl_verfiy_host") {
                            $ssl_verify = $values[1];
                            $ssl_verify =~s/\s//g;
                        }
                    }
                    when ("performance") {
                        my @values = split ("=",$configline);
                        if($configline =~ "max_metrics_per_minute") {
                            $maxmetricsperminute = $values[1];
                        }
                    }
                    default {
                        $arrayserial = $section;
                        #print $conf_storagename."\n";
                        my @values = split ("=",$configline);
                        $values[1] =~ s/\s//g;
                        if($configline =~ "subsystem_type") {
                            my @values = split ("=",$configline);
                            $arraytype = $values[1];
                            $arraytype =~ s/\s//g;
                            $arraytype = lc($arraytype);
                        } elsif ($configline =~ "subsystem_name") {
                            my @values = split ("=",$configline);
                            $conf_storagename = $values[1];
                            $conf_storagename =~ s/\s//g;
                            $conf_storagename = uc($conf_storagename);
                            $arrays{$conf_storagename}{"serial"}=$arrayserial;
                            $arrays{$conf_storagename}{"type"}=$araytype;
                        } elsif ($configline =~ "realtime_appliction") {
                            $arrays{$conf_storagename}{"realtime_application"}=$values[1];
                        } elsif ($configline =~ "realtime_api_host") {
                            $arrays{$conf_storagename}{"realtime_api_host"}=$values[1];
                        } elsif ($configline =~ "realtime_api_port") {
                            $arrays{$conf_storagename}{"realtime_api_port"}=$values[1];
                        } elsif ($configline =~ "realtime_api_proto") {
                            $arrays{$conf_storagename}{"realtime_api_proto"}=$values[1];
                        } elsif ($configline =~ "realtime_api_user") {
                            $arrays{$conf_storagename}{"realtime_api_user"}=$values[1];
                        } elsif ($configline =~ "realtime_api_passwd") {
                            $arrays{$conf_storagename}{"realtime_api_passwd"}=$values[1];
                        } elsif ($configline =~ "gad_vsm") {
                            my @gad_vsm_strings = split(",",$values[1]);
                            my $gad_sn=$gad_vsm_strings[0];
                            my $gad_vsm_type = $gad_vsm_strings[1];
                            my $gad_name=$gad_vsm_strings[2];
                            my $gad_rgid=$gad_vsm_strings[3];
                            $vsms{$conf_storagename}{$gad_sn}{"name"} = $gad_name;
                            $vsms{$conf_storagename}{$gad_sn}{"type"} = $gad_vsm_type;
                            $vsms{$conf_storagename}{$gad_sn}{"rsgid"} = $gad_rgid;
                        } elsif ($configline =~ "max_metrics_per_minute") {
                            $configline =~ s/\s//g;
                            my @values = split ("=",$configline);
                            $maxmetricsperminute = $values[1];
                        } elsif ($configline =~ "ssl_verfiy_host") {
                            $arrays{$conf_storagename}{"ssl_verfiy_host"} = $values[1];
                        }
                    }
                }
            }
        }
    }
    close($fh);
    setdefaults();
    if($htnm_appl eq "HTNM") {
        $htnm_appl = 'TuningManager';
    } elsif ($htnm_appl eq "HIAA") {
        $htnm_appl = 'Analytics/RAIDAgent';
    } else {
        print("Unknon API type specified \"".$htnm_appl."\" please check!\n");
        exit(1);
    }
    $htnm_rest_base_url = $htnm_proto.'://'.$htnm_server.':'.$htnm_port.'/'.$htnm_appl.'/v1/objects/';
}

sub setdefaults {
    if(defined $arrays{$storagename}{"realtime_application"}) {
        $htnm_appl = $arrays{$storagename}{"realtime_application"};
    }
    if(defined $arrays{$storagename}{"realtime_api_host"}) {
        $htnm_server = $arrays{$storagename}{"realtime_api_host"};
    }
    if(defined $arrays{$storagename}{"realtime_api_port"}) {
        $htnm_port = $arrays{$storagename}{"realtime_api_port"};
    }
    if(defined $arrays{$storagename}{"realtime_api_proto"}) {
        $htnm_proto = $arrays{$storagename}{"realtime_api_proto"};
    }
    if(defined $arrays{$storagename}{"realtime_api_user"}) {
        $htnm_user = $arrays{$storagename}{"realtime_api_user"};
    }
    if(defined $arrays{$storagename}{"realtime_api_passwd"}) {
        $htnm_passwd = $arrays{$storagename}{"realtime_api_passwd"};
    }
	if(defined $arrays{$storagename}{"realtime_api_passwd"}) {
        $ssl_verify = $arrays{$storagename}{"ssl_verfiy_host"};
    }
}

sub http_get {
    my $geturl = $_[0];
    my $req = HTTP::Request->new(GET => $geturl);
    $req->header('Content-Type' => 'application/json');
    $req->authorization_basic($htnm_user,$htnm_passwd);
    my $curlcmd = 'curl -ks -X GET -H "Content-Type: application/json" -u '.$htnm_user.':'.$htnm_passwd.' -i '.$geturl;
    my $debugcmd = 'curl -ks -X GET -H "Content-Type: application/json" -u '.$htnm_user.':xxxxxxxxx'.' -i '.$geturl;
    $log->debug($debugcmd);
    my $resp = $ua->request($req);
    if ($resp->is_success) {
        my $responsecontent = $resp->decoded_content;
        return($responsecontent);
    } else {
        $log->error("Failed to GET data from ".$geturl." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$geturl." with HTTP GET error message: ".$resp->message);
        $log->error("Exit hds2grahite due to failed HTTP GET Operation! Please check URL!");
        exit(($resp->code)-100);
    }
}

sub getldevs {
    %ldevs = ();
    $log->debug("Retrieving LDEV configugration!");
    my $retrieve_url = $htnm_rest_base_url.'RAID_PD_LDC?hostName='.$instance_hostname.'&agentInstanceName='.$instance;
    my @result = split(/\n/,http_get($retrieve_url));
    my $line_cnt = 1;
    my %header;
    my @headerarray=();
    foreach my $line (@result) {
    $line =~ s/\"//g;
    chop($line);
    if($line_cnt == 1) {
        @headerarray = split(",",$line);
        for (my $i=0;$i<scalar(@headerarray);$i+=1) {
            $header{$headerarray[$i]}{"position"}=$i;
        }
    } elsif ($line_cnt == 2) {
        my @values = split(",",$line);
        for (my $i=0;$i<scalar(@values);$i+=1) {
                $header{$headerarray[$i]}{"unit"}=$values[$i];
        }
    } elsif (length($line)>=2) {
        my @values = split(",",$line);
        my $ldev_id = $values[$header{'LDEV_NUMBER'}{'position'}];
        my $parity_grp = $values[$header{'RAID_GROUP_NUMBER'}{'position'}];
        my $pool_id = $values[$header{'POOL_ID'}{'position'}];
        my $mp_id = $values[$header{'MP_BLADE'}{'position'}];
        my $vldev_id = $values[$header{'VIRTUAL_LDEV_NUMBER'}{'position'}];
        my $v_sn = $values[$header{'VIRTUAL_SERIAL_NUMBER'}{'position'}];
        $ldevs{$ldev_id}{'parity_grp'} = $parity_grp;
        $ldevs{$ldev_id}{'pool_id'} = $pool_id;
        $ldevs{$ldev_id}{'mp_id'} = $mp_id;
        $ldevs{$ldev_id}{'vldev_id'} = $vldev_id;
        $ldevs{$ldev_id}{'vsn'} = $v_sn;
        $log->trace($ldev_id.": ".$ldevs{$ldev_id}{'parity_grp'}." => ".$ldevs{$ldev_id}{'pool_id'}." => ".$ldevs{$ldev_id}{'mp_id'}." => ".$ldevs{$ldev_id}{'vldev_id'}." => ".$ldevs{$ldev_id}{'vsn'});
    }
    $line_cnt += 1;
    }
}

sub getagents {
    my $retrieve_url = $htnm_rest_base_url.'Agents?agentType=ALL';
    my $http_result = http_get($retrieve_url);
    if($http_result =~ "{") {
        my %json = %{decode_json($http_result)};
        my @items = $json{"items"};
        foreach my $item (@items) {
            my @agents= @{$item};
            foreach my $agent (@agents) {
                my %agent_elements = %{$agent};
                my $instanceName = "";
                my $ipAddr = "";
                my $storageModel = "";
                my $storageSerialNumber = "";
                my $agentType = "";
                my $hostName = "";
                foreach my $key (sort keys %agent_elements) {
                    if($key eq "instanceName") {
                        $instanceName = $agent_elements{$key};
                    } elsif ($key eq "ipAddr") {
                        $ipAddr = $agent_elements{$key};
                    } elsif ($key eq "storageModel") {
                        $storageModel = $agent_elements{$key};
                    } elsif ($key eq "storageSerialNumber") {
                        $storageSerialNumber = $agent_elements{$key};
                    } elsif ($key eq "agentType") {
                        $agentType = $agent_elements{$key};
                    } elsif ($key eq "hostName") {
                        $hostName = $agent_elements{$key};
                    }
                }
                $htnm_agents{$storageSerialNumber}{"instanceName"} = $instanceName;
                $htnm_agents{$storageSerialNumber}{"ipAddr"} = $ipAddr;
                $htnm_agents{$storageSerialNumber}{"storageModel"} = $storageModel;
                $htnm_agents{$storageSerialNumber}{"agentType"} = $agentType;
                $htnm_agents{$storageSerialNumber}{"hostName"} = $hostName;
                $log->debug("Found Agent: ".$instanceName." with attributes: ipAddr => ".$ipAddr." storageSerialNumber => ".$storageSerialNumber." storageModel => ".$storageModel." agentType => ".$agentType." hostName => ".$hostName);
            }
        }
    }
}

sub reportmetric {
    my $unit = $_[0];
    my $now = time;
    my $lastrun = 0;
    my $lastldevtime = 0;

    while(true) {
        sleep(1);
        $now = time;
        if(($unit eq "RAID_PI_LDS") && (($now-$lastldevtime)> 3600)) {
            $lastldevtime = $now;
            getldevs();
        }
        if(($now-$lastrun)>(($interval)+5)) {
            initsocket();
            my $retrieve_url = $htnm_rest_base_url.$unit.'?hostName='.$instance_hostname.'&agentInstanceName='.$instance;
            my @result = split(/\n/,http_get($retrieve_url));
            my $line_cnt = 1;
            my %header;
            my @headerarray=();
            foreach my $line (@result) {
                chop($line);
                if($line_cnt == 1) {
                    @headerarray = split(",",$line);
                    for (my $i=0;$i<scalar(@headerarray);$i+=1) {
                        $header{$headerarray[$i]}{"position"}=$i;
                    }
                } elsif ($line_cnt == 2) {
                    my @values = split(",",$line);
                    for (my $i=0;$i<scalar(@values);$i+=1) {
                        $header{$headerarray[$i]}{"unit"}=$values[$i];
                    }
                } elsif (length($line)>=2) {
                    my @values = split(",",$line);
                    my @labels = @{$labels{$unit}};
                    my $labelcontent="";
					my $taglabel;
                    for(my $i=0;$i<scalar(@labels);$i+=1) {
                        my $label = $labels[$i];
                        if($i==0) {
                            if(defined $header{$label}{"position"}) {
                                if($usetag) {
                                    $taglabel=lc($label).'='.$values[$header{$label}{"position"}];
                                } 
	                            $labelcontent=$values[$header{$label}{"position"}];
                            } else {
                                if($usetag) {
                                    $taglabel='label='.$label;
                                }
                            $labelcontent=$label;
                            }
                        } else {
                            if(defined $header{$label}{"position"}) {
                                if($usetag) {
                                    $taglabel.=';'.lc($label).'='.$values[$header{$label}{"position"}];
                                }
                                $labelcontent.='.'.$values[$header{$label}{"position"}];
                            } else {
                                if($usetag) {
                                    $taglabel='label='.$label;
                                }
                                $labelcontent.='.'.$label;
                            }
                        }
                        $labelcontent =~s/\"//g;
                        $taglabel =~s/\"//g;
                    }
                    foreach my $metric (@{$metrics{$unit}}) {
                        my $metric_value = $values[$header{$metric}{"position"}];
                        my $metric_unit = $header{$metric}{"unit"};
                        if (($metric_unit eq "float") || ($metric_unit eq "double")) {
                            my @numberparts = split('E',$metric_value);
                            my $basenumber = $numberparts[0];
                            my $power = $numberparts[1];
                            $power =~ s/\+//g;
                            if($power < 0) {
                                $metric_value=$basenumber / (10**(-1*$power));
                            } elsif($power > 0) {
                                $metric_value= $basenumber * (10**$power);
                            } elsif ($power == 0) {
                                $metric_value= $basenumber;
                            }
                        }
                        my $timefromresponse = $values[$header{"DATETIME"}{"position"}];
                        my $timeoffset = $values[$header{"GMT_ADJUST"}{"position"}];
                        my $curtime = Time::Piece->strptime($timefromresponse, $hdsdateformat);
                        my $graphitetime = $curtime->epoch;
                        my $target = $unit;
                        if(defined $targets{$unit}) {
                            $target = $targets{$unit};
                        }
                        my $importmetric='REALTIME_'.$metric;
                        my $graphitemetric = "";
                        if($unit eq 'RAID_PI_LDS') {
                            my $parity_grp = $ldevs{$labelcontent}{'parity_grp'};
                            my $pool_id = $ldevs{$labelcontent}{'pool_id'};
                            my $mp_id = $ldevs{$labelcontent}{'mp_id'};
                            if ($parity_grp ne '') {
                                $graphitemetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.'.$target.'.PG.'.$parity_grp.'.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
                                if($usetag) {
                                    $graphitemetric = 'hv_'.lc($target).'_'.lc($importmetric).';entity=physical;storagetype='.$storagetype.';storagename='.$storagename.';type=pg;pg_id='.$parity_grp.';'.$taglabel.' '.$metric_value.' '.$graphitetime;
                                }
                            } else {
                                if($pool_id ne '') {
                                    $pool_id = sprintf("%03d",$pool_id);
                                    $graphitemetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.'.$target.'.DP.'.$pool_id.'.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
                                    my $mpmetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.PRCS.'.$mp_id.'.LDEV.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
                                    if($usetag) {
                                        $graphitemetric = 'hv_'.lc($target).'_'.lc($importmetric).';entity=physical;storagetype='.$storagetype.';storagename='.$storagename.';mp_id='.$mp_id.';type=dp;pool_id='.$pool_id.';'.$taglabel.' '.$metric_value.' '.$graphitetime;
                                    }
                                    if($ldevs{$labelcontent}{'vldev_id'} ne '') {
                                        my $virt_ldev = $ldevs{$labelcontent}{'vldev_id'};
                                        my $virt_storage_sn = $ldevs{$labelcontent}{'vsn'};
										$log->trace("Found virtual ldev: ".$virt_ldev." from serial: ".$virt_storage_sn);
                                        my $virt_storage_name = $vsms{$storagename}{$virt_storage_sn}{'name'};
                                        my $virt_storage_type = $vsms{$storagename}{$virt_storage_sn}{'type'};
                                        my $virtmetric = 'hds.perf.virtual.'.$virt_storage_type.'.'.$virt_storage_name.'.'.$target.'.DP.'.$pool_id.'.'.$virt_ldev.'.'.$storagename.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
                                        if($usetag) {
                                            $virtmetric = 'hv_'.lc($target).'_'.lc($importmetric).';entity=virtual;storagetype='.$virt_storage_type.';storagename='.$virt_storage_name.';type=dp;pool_id='.$pool_id.';'.$taglabel.';phys_storagename='.$storagename.' '.$metric_value.' '.$graphitetime;
                                        }
                                        toGraphite($virtmetric);
                                    }
                                }
                            }
                        } else {
                            $graphitemetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.'.$target.'.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
                            if($usetag) {
                                $labelcontent =~ s/\./_/g;
                                $graphitemetric = 'hv_'.lc($target).'_'.lc($importmetric).';entity=physical;storagetype='.$storagetype.';storagename='.$storagename.';unit='.$target.';'.$taglabel.' '.$metric_value.' '.$graphitetime;
                            }
                        }
                        toGraphite($graphitemetric);
                        $interval = $values[$header{"INTERVAL"}{"position"}];
                        $lastrun = $graphitetime;
                    }
                }
                $line_cnt += 1;
            }
            closesocket();
            $log->info("Processed: ".$unit.":   Started ".strftime('%Y/%m/%d %H:%M:%S',gmtime($now))." and received metrics for time: ".strftime('%Y/%m/%d %H:%M:%S',gmtime($lastrun)));
            #$lastrun = $now;
        }
    }
}

sub initializereporter {
    my $serial = $arrays{$storagename}{"serial"};
    $storagetype = $arrays{$storagename}{"type"};
    $instance = $htnm_agents{$serial}{"instanceName"};
    $instance_hostname = $htnm_agents{$serial}{"hostName"};
    if($instance eq "" or $instance_hostname eq "") {
	$log->error("No HTNM / HIAA / Analyzer Instance found for ".$storagename."! Please check");
	stopservice();
	exit(1);	
    }
    my $metricfile = $metricpath.'/'.$storagetype.'_realtime_metrics.conf';

    if(!-e $metricfile) {
        $log->error("Cannot find metric file for array type ".$storagetype.". Please check ".$metricfile);
        exit(1);
    } else {
        open my $metricfh,'<',$metricfile or $log->logdie("Cannot open File $!");
        my $unit = '';
        while(<$metricfh>) {
            my $line = $_;
            if(($line !~ "^#") and (length($line) > 3)) {
                if($line =~ '^\[') {
                    $unit = $line;
                    $unit =~ s/\[//g;
                    $unit =~ s/\]//g;
                    $unit =~ s/\s//g;
                    push(@units,$unit);
                } elsif ($line =~ "label") {
                    $line =~ s/\s//g;
                    chomp($line);
                    my @values = split('=',$line);
                    my @metriclabels = split(',',$values[1]);
                    $labels{$unit}=[@metriclabels];
                } elsif ($line =~ "metrics") {
                    $line =~ s/\s//g;
                    chomp($line);
                    my @values = split('=',$line);
                    my @definedlabels = split(',',$values[1]);
                    $metrics{$unit} = [@definedlabels];
                } elsif ($line =~ "target") {
                    $line =~ s/\s//g;
                    chomp($line);
                    my @values = split('=',$line);
                    $targets{$unit} = $values[1];
                }
            }
        }
    }

}

sub startreporter {
    servicestatus('Running reporters...');
    foreach my $unit (@units) {
        my $pid = fork();
        if(!$pid) {
            reportmetric($unit);
        } else {
            $pids{$unit}=$pid;
        }
    }
}

sub checkreporter {
    my $livecounter = 0;
    while(true) {
        foreach my $unit (sort keys %pids) {
            my $res = waitpid($pids{$unit}, WNOHANG);
            if ($res) {
                my $rc = $?>>8;
                $log->error("Looks like PID: ".$pids{$unit}." for unit ".$unit." is not running! It ended with returncode ".$rc);
                $log->error("Restarting for Unit: ".$unit);
                sleep(10);
                my $pid = fork();
                if(!$pid) {
                        reportmetric($unit);
                } else {
                        $pids{$unit}=$pid;
                }
            }
        }
        if($livecounter > 6) {
            alive();
            $livecounter = 0;
        }
        $livecounter += 1;
        sleep(1);
    }
}

sub initsocket {
        $socket = new IO::Socket::INET (
        PeerHost => $graphite_host,
        PeerPort => $graphite_port,
        Proto => 'tcp',
        );
        $log->logdie ("cannot connect to the server $!") unless $socket;
        setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
        $log->debug("Opening connection ".$socket->sockhost().":".$socket->sockport()." => ".$socket->peerhost().":".$socket->peerport());
}

# sub to close socket to graphite host
#
sub closesocket {
         $log->debug("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
         $socket->shutdown(2);
}

sub toGraphite() {
    $socketcnt+=1;
    my $message = $_[0];
    $socket->send($message."\n");
    # not every message will be delayed to allow quick systems to be utilized. Delay will only happen when the delay time is larger than 0ns since nanosleep(0) will consume time.
    if(($socketdelay>0)&&!($socketcnt % $delaymetric)) {
        nanosleep($socketdelay);
    }
    # every 100.000 inserts we will check how long it takes for 100.000 in obejcts to insert. The delay will be adjusted based on this result compared to the maximum amount of metrics that should be imported.
    if($socketcnt>=100000) {
        my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
        my $metricsperminute = 60/$elapsed*100000;
        if($socketdelay>0) {
            $socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
            # in case of running as service avoid that oversized delay will trigger the watchdog
            if($socketdelay > $maxdelay) {
                $socketdelay = $maxdelay;
            }
        } else {
            # if the delay was going down to 0ns there need to be a possibility to increase the delay again starting with 1us.
            $socketdelay = int(1000*($metricsperminute/$maxmetricsperminute));
        }
        $log->debug("Elapsed time for last 100.000 Metrics: ".sprintf("%.2f",$elapsed)."s => metrics per minute: ".sprintf("%.2f",$metricsperminute)." new delay: ".$socketdelay);
        $sockettimer = [gettimeofday];
        $socketcnt = 0;
    }
}

# Sub to initialize Systemd Service

sub initservice {
    if(defined $ENV{'NOTIFY_SOCKET'}) {    
        if($mainpid == $$) {
        	my $sock = IO::Socket::UNIX->new(
            	Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
    	    ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "READY=1\n";
            $log->info("Service is initialized...");
            close($sock)
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}


# Sub to update status of Systemd Service when running as Daemon

sub servicestatus {
    my $message = $_[0];
    if(defined $ENV{'NOTIFY_SOCKET'}) {
        if($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "STATUS=$message\n";
            $log->trace("Servicemessage has been send: ".$message);
            close($sock);
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to signal a stop of the script to the service when running as Daemon

sub stopservice {
    if(defined $ENV{'NOTIFY_SOCKET'}) {
        if($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "STOPPING=1\n";
            $log->info("Service is shutting down...");
            close($sock);
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}

# Sub to send heartbeat to watchdog of Systemd service when running as Daemon.

sub alive {
    if(defined $ENV{'NOTIFY_SOCKET'}) {
        if($mainpid == $$) {
            my $sock = IO::Socket::UNIX->new(
                Type => SOCK_DGRAM(),
                Peer => $ENV{'NOTIFY_SOCKET'},
            ) or $log->logdie("Unable to open socket for systemd communication");
            print $sock "WATCHDOG=1\n";
            $log->trace("Watchdog message has been send to systemd...");
            close($sock);
        }
    } else {
        $log->trace("Looks like we are not runnings as systemd-service!");
    }
}


# Main
#
parseCmdArgs();

$logfile=$logpath.'hds2graphite-realtime-'.$storagename.'.log';

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

if($ssl_verify == 0) {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0, SSL_verify_mode=>0x00 });
} else {
    $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 1 });
}


initservice();
servicestatus('Getting agents...');
alive();
getagents();
servicestatus('Initializing reporters...');
alive();
initializereporter();
servicestatus('Starting reporters...');
alive();
startreporter();
servicestatus('Running reporters...');
alive();
checkreporter();
