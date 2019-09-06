#!/bin/perl
#
#
#	Script for realtime data import from HTNM / HIAA to graphite
#
#

use strict;
use warnings;

use lib '/opt/hds2graphite/lib/perl5/';

use Switch;
use LWP::UserAgent();
use POSIX qw(strftime);
use POSIX ":sys_wait_h";
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use IO::Socket::INET;
use Time::Piece;
use Log::Log4perl;
use Getopt::Long;
use JSON;
use Systemd::Daemon qw( -hard notify );

use constant false => 0;
use constant true  => 1;


my $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });

my $htnm_server = '';
my $htnm_port = '';
my $htnm_proto = '';
my $htnm_appl = '';
my $htnm_user = '';
my $htnm_passwd = '';
my $htnm_rest_base_url = '';

my $graphite_host = '';
my $graphite_port = '';

my $socketcnt = 0;
my $sockettimer;
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;
my $socket;

my $metricpath = '/opt/hds2graphite/conf/metrics/';

my $watchdog = 300;
# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts. The factor 0.9 adds in some tollerance to av
# aid watchdog is killing service because delay for inserts is to high! This might happen if the 1st 100.000 inserts are done in less than 2 seconds...
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;

my %arrays;
my $storagename="";
my $storagetype="";
my %htnm_agents;
my $instance = '';
my $instance_hostname = '';
#my @units = ('RAID_PI_PTS','RAID_PI_PRCS');
#my %metrics = (
#	'RAID_PI_PTS' => ['READ_IO_COUNT','READ_IO_RATE','WRITE_IO_COUNT','WRITE_IO_RATE','TOTAL_IO_COUNT','MAX_IO_RATE','MIN_IO_RATE','AVG_IO_RATE','READ_MBYTES','READ_XFER_RATE','WRITE_MBYTES','WRITE_XFER_RATE','TOTAL_MBYTES','MAX_XFER_RATE','MIN_XFER_RATE','AVG_XFER_RATE','READ_TOTAL_RESPONSE','READ_RESPONSE_RATE','WRITE_TOTAL_RESPONSE','WRITE_RESPONSE_RATE','INITIATOR_TOTAL_IO_COUNT','INITIATOR_MAX_IO_RATE','INITIATOR_MIN_IO_RATE','INITIATOR_AVG_IO_RATE','INITIATOR_TOTAL_MBYTES','INITIATOR_MAX_XFER_RATE','INITIATOR_MIN_XFER_RATE','INITIATOR_AVG_XFER_RATE'],
#	'RAID_PI_PRCS' => ['PROCESSOR_BUSY_RATE','MAX_PROCESSOR_BUSY_RATE','MAX_BUFFER_LENGTH','BUFFER_IO_COUNT','MAX_BUFFER_IO_COUNT','BUFFER_IO_RATE','MAX_BUFFER_IO_RATE'],
#);

#my %labels = (
#	'RAID_PI_PTS'=>['PORT_NAME'],
#	'RAID_PI_PRCS'=>['ADAPTOR_ID','PROCESSOR_ID'],
#);

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
my $logfile='';
my $loglevel = 'INFO';

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

	if(!-e $conf) {
		print("Configurationfile cannot be found. Please check file: ".$conf."\n\n");
	} else {
		readconfig($conf);
	}

	if(!defined $arrays{$storagename}{"serial"}) {
		print("Cannot find ".$storagename." in ".$conf."! Please check configuration file or correct storagename parameter.\n");
		exit(1);
	}

}

sub readconfig {
	my $configfilename = $_[0];
	#print $configfilename."\n";
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
				switch($section) {
					case "logging" {
                                                my @values = split ("=",$configline);
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
					case "graphite" {
                                                my @values = split ("=",$configline);
                                                if($configline =~ "host") {
                                                        $graphite_host = $values[1];
                                                        $graphite_host =~ s/\s//g;
                                                } elsif ($configline =~ "port") {
                                                        $graphite_port = $values[1];
                                                        $graphite_port =~ s/\s//g;
                                                }
                                        }
					case "realtime" {
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
                                                }
					}
					case "performance" {
                                                my @values = split ("=",$configline);
                                                if($configline =~ "max_metrics_per_minute") {
                                                        $maxmetricsperminute = $values[1];
                                                }
                                        }
					else {
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
                                                	$arrays{$conf_storagename}{"type"}=$arraytype;
                                                } elsif ($configline =~ "realtime_application") {
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
	#print $htnm_rest_base_url."\n";
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

}


sub http_get {
        my $geturl = $_[0];
        my $req = HTTP::Request->new(GET => $geturl);
        $req->header('Content-Type' => 'application/json');
	$req->authorization_basic($htnm_user,$htnm_passwd);
        my $curlcmd = 'curl -ks -X GET -H "Content-Type: application/json" -u '.$htnm_user.':'.$htnm_passwd.' -i '.$geturl;
	$log->debug($curlcmd);
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
					for(my $i=0;$i<scalar(@labels);$i+=1) {
						my $label = $labels[$i];
						if($i==0) {
							if(defined $header{$label}{"position"}) {
								$labelcontent=$values[$header{$label}{"position"}];
							} else {
								$labelcontent=$label;
							}
						} else {
							if(defined $header{$label}{"position"}) {
								$labelcontent.='.'.$values[$header{$label}{"position"}];
							} else {
								$labelcontent.='.'.$label;
							}
						}
						$labelcontent =~s/\"//g;
					}
					foreach my $metric (@{$metrics{$unit}}) {
						my $metric_value = $values[$header{$metric}{"position"}];
						my $metric_unit = $header{$metric}{"unit"};
						if ($metric_unit eq "float") {
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
							} else {
								if($pool_id ne '') {
									$pool_id = sprintf("%03d",$pool_id);		
									$graphitemetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.'.$target.'.DP.'.$pool_id.'.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
									my $mpmetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.PRCS.'.$mp_id.'.LDEV.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
									toGraphite($mpmetric);
									
									if($ldevs{$labelcontent}{'vldev_id'} ne '') {
										my $virt_ldev = $ldevs{$labelcontent}{'vldev_id'};
										my $virt_storage_sn = $ldevs{$labelcontent}{'vsn'};
										my $virt_storage_name = $vsms{$storagename}{$virt_storage_sn}{'name'};
										my $virt_storage_type = $vsms{$storagename}{$virt_storage_sn}{'type'};
										#print("Virt-LDEV: ".$virt_ldev." ".$virt_storage_sn." ".$virt_storage_name." ".$virt_storage_type."\n";
										my $virtmetric = 'hds.perf.virtual.'.$virt_storage_type.'.'.$virt_storage_name.'.'.$target.'.DP.'.$pool_id.'.'.$virt_ldev.'.'.$storagename.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
										toGraphite($virtmetric);
									}									
#print $mpmetric."\n";
								}
							}

							
							
						} else {
							$graphitemetric = 'hds.perf.physical.'.$storagetype.'.'.$storagename.'.'.$target.'.'.$labelcontent.'.'.$importmetric.' '.$metric_value.' '.$graphitetime;
						}
						#print $graphitemetric."\n";
						toGraphite($graphitemetric);
						$interval = $values[$header{"INTERVAL"}{"position"}];
						$lastrun = $graphitetime;
					}
				}
				$line_cnt += 1;
			}
			closesocket();
			#print "Processed: ".$unit.":   Started ".strftime('%Y/%m/%d %H:%M:%S',gmtime($now))." and received metrics for time: ".strftime('%Y/%m/%d %H:%M:%S',gmtime($lastrun))."\n";
			$log->info("Processed: ".$unit.":   Started ".strftime('%Y/%m/%d %H:%M:%S',gmtime($now))." and received metrics for time: ".strftime('%Y/%m/%d %H:%M:%S',gmtime($lastrun)));
			#$lastrun = $now;
		}
	}
}

sub initializereporter {
	my $serial = $arrays{$storagename}{"serial"};
	$storagetype = $arrays{$storagename}{"type"};
	#print ">".$serial."<\n";
	#print ">".$storagetype."<\n";
	$instance = $htnm_agents{$serial}{"instanceName"};
	$instance_hostname = $htnm_agents{$serial}{"hostName"};

	my $metricfile = $metricpath.'/'.$storagetype.'_realtime_metrics.conf';
	
	if(!-e $metricfile) {
		$log->error("Cannot find metric file for arraytype ".$storagetype.". Please check ".$metricfile);
		exit(1);
	} else {
		open my $metricfh,'<',$metricfile or die "Cannot open File $!";
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
					#foreach my $test (@{$labels{$unit}}) {
					#	print $unit."=> Label => ".$test."\n";
					#}
				} elsif ($line =~ "metrics") {
					$line =~ s/\s//g;
                                        chomp($line);
                                        my @values = split('=',$line);
					my @definedlabels = split(',',$values[1]);
					$metrics{$unit} = [@definedlabels];
					#foreach my $test (@{$metrics{$unit}}) {
					#	print $unit." => ".$test."\n";
					#}
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
		if($livecounter > 60) {
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
        die "cannot connect to the server $!\n" unless $socket;
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
        # not every message will be delayed since to allow quick systems to be utilized. Delay will only happen when the delay time is larger than 0ns since nanosleep(0) will consume time.
        if(($socketdelay>0)&&!($socketcnt % $delaymetric)) {
        	nanosleep($socketdelay);
        }
        # every 100.000 inserts we will check how long it takes for 100.000 in obejcts to insert. The delay will be adjusted base on this result compared to the maximum amount of metrics that should be imported.
        if($socketcnt>=100000) {
        	my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
                my $metricsperminute = 60/$elapsed*100000;
                if($socketdelay>0) {
                	$socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
                        # in case of running as service avoid that to large delay will trigger the watchdog...
                        if($socketdelay > $maxdelay) {
                                  $socketdelay = $maxdelay;
                        }
        	} else {
                	# if the delay was going down to 0ns there need to be a possibility to increase the delay again starting with 1us.
                	$socketdelay = int(1000*($metricsperminute/$maxmetricsperminute));
        	}
        	#$log->info("Elapsed time for last 100.000 Metrics: ".sprintf("%.2f",$elapsed)."s => metrics per minute: ".sprintf("%.2f",$metricsperminute)." new delay: ".$socketdelay);
        	$sockettimer = [gettimeofday];
       	 	$socketcnt = 0;
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

# Sub to send heartbeat wo watchdog of Systemd service when running as Daemon.

sub alive {
	notify ( WATCHDOG => 1 );
	if($loglevel eq "TRACE") {
		$log->trace("Heartbeat is send to watchdog of service...");
	}
}


# Main
#
parseCmdArgs();

$logfile='/opt/hds2graphite/log/hds2graphite-realtime-'.$storagename.'.log';

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









