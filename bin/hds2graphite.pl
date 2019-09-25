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
#  Initially written: 13.11.2017
#
#  Description      : Script controls the services responsible for importing the performance data of HDS storage systems
#
# ==============================================================================================


use v5.10;
use strict;
use warnings;
use constant false => 0;
use constant true  => 1;

use Getopt::Long;
use Log::Log4perl;
use POSIX qw(strftime);


# For all initially initialized variables, values represent defaults used if they are not specified via configfile
# log variables
my $log; # log4perl logger
my $logpath = '/opt/hds2graphite/log/';
my $logname = 'hds2graphite.log';
my $logfile = "";
my $loglevel = 'INFO';

# command arguments variables
my $register ='';
my $deregister ='';
my $enable ='';
my $disable ='';
my $start ='';
my $stop ='';
my $restart ='';
my $status ='';
my $help;
my $realtime;
my $conf = '/opt/hds2graphite/conf/hds2graphite.conf';
my $realtime_conf = '/opt/hds2graphite/conf/hds2graphite-realtime.conf';

# service parameters
my $runeveryhours = 1;
my $minafterfullhours = 0;
my $serviceuser = 'openiomon';
my $servicegroup = 'openiomon';
my $watchdog = 300;
my $libdir = "/opt/hds2graphite/lib/";
my $workdir = "/opt/hds2graphite/";
my $stdoutopt = 'null';
my $stderropt = 'null';

# hash for storage systems in configfile

my %storage;
my %rt_storage;

# variables for automatic CCI installation

my $preparecci = "";
my $ccipath = '/opt/hds2graphite/cci/';
my $cciimage = $ccipath.'RMHORC';

sub console {
    my $message = shift;
    print $message,"\n";
    $log->info($message);
}

# Sub to print the parameter reference

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    #print("   -conf         <file>          conf file containig parameter for the import\n");
    print("   -register     <name or ALL>   name of the storage system to be registerd as service\n");
    print("   -deregister   <name or ALL>   name of the storage system which service should be deregisterd\n");
    print("   -enable       <name or ALL>   activate automatic service start for the storagesystem\n");
    print("   -disable      <name or ALL>   deactivate automatic service start for the storagesystem\n");
    print("   -start        <name or ALL>   start for the service for the storagesystem\n");
    print("   -stop         <name or ALL>   stop for the service for the storagesystem\n");
    print("   -restart      <name or ALL>   restart for the service for the storagesystem\n");
    print("   -status       <name or ALL>   status of the service for the storagesystem\n");
    print("   -realtime                     if this option is specified actions (register, deregsiter, start, stop, enable, disable, status) \n");
    print("   -preparecci                   this option will install and configure CCI to be used for hds2graphite. CCI Image need to be stored at /opt/hds2graphite/CCI/RMHORC. \n");
    print("                                 will be performed for realtime collections services.\n");
    print("   -h                            print this output\n");
    print("\n");
}

sub parseCmdArgs {
    my $help = "";
    GetOptions (    "conf=s"            => \$conf,              # String
                    "register=s"        => \$register,          # String
                    "deregister=s"      => \$deregister,        # String
                    "enable=s"          => \$enable,            # String
                    "disable=s"         => \$disable,           # String
                    "start=s"           => \$start,             # String
                    "stop=s"            => \$stop,              # String
                    "restart=s"         => \$restart,           # String
                    "status=s"          => \$status,            # String
                    "realtime"          => \$realtime,          # flag
                    "preparecci"        => \$preparecci,        # flag
                    "h"                 => \$help)              # flag
    or die("Error in command line arguments\n");

    if($help) {
        printUsage();
        exit(0);
    }

    # Wrong or missing config file?
    if(!-f $conf) {
        print "Configuration file: ".$conf." cannot be found! Please specify configuration file!\n\n";
        printUsage();
        exit(1);
    } else {
        # read config file to get params
        readconfig();
    }

    if(($register eq "") && ($deregister eq "") && ($enable eq "") && ($disable eq "") && ($start eq "") && ($stop eq "") && ($restart eq "") && ($status eq "") && ($preparecci eq "")) {
        printUsage();
        exit(1);
    }

    if(($register ne "") && ($deregister ne "")) {
        print "Cannot register and deregister service at the same time!\n";
        exit(1);
    }

    if(($enable ne "") && ($disable ne "")) {
        print "Cannot enable and disable service at the same time!\n";
        exit(1);
    }

    if(($start ne "") && ($stop ne "")) {
        print "Cannot start and stop service at the same time!\n";
        exit(1);
    }

    if(($start ne "") && ($restart ne "")) {
        print "Cannot start and restart service at the same time!\n";
        exit(1);
    }

    if(($stop ne "") && ($restart ne "")) {
        print "Cannot stop and restart service at the same time!\n";
        exit(1);
    }

}

sub readconfig {
    # Open the configfile for hds2graphite-worker.pl
    open my $configfilefp, '<', $conf or die "Can't open file: $!";
    my $section = "";
    my $conf_storagename = "";
    my $arraytype = "";
    my $arrayserial = "";
    while(<$configfilefp>) {
        my $configline = $_;
        chomp ($configline);
        # Skip all line starting with a # (hash)
        if (($configline !~ "^#") && ($configline ne "")){
            # read the section from the configfile
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
                            $logpath = $values[1];
                            $logpath =~ s/\s//g;
                            if(substr($logpath,-1) ne "/") {
                                    $logpath = $logpath."/";
                            }
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
                    when ("service") {
                        my @values = split ("=",$configline);
                        if($configline =~ "service_run_every_hours") {
                            $runeveryhours = $values[1];
                            $runeveryhours =~ s/\s//g;
                        } elsif ($configline =~ "service_run_minutes_after_hour") {
                            $minafterfullhours = $values[1];
                            $minafterfullhours =~ s/\s//g;
                        } elsif ($configline =~ "serviceuser") {
                            $serviceuser = $values[1];
                        } elsif ($configline =~ "servicegroup") {
                            $servicegroup = $values[1];
                        } elsif ($configline =~ "watchdogtimeout") {
                            $watchdog = $values[1];
                        } elsif ($configline =~ "libdirectory") {
                            $libdir = $values[1];
                            my $lastchar = substr($libdir,-1);
                            if($lastchar ne "\/") {
                                $libdir.="\/";
                            }
                        } elsif ($configline =~ "workingdirectory") {
                            $workdir = $values[1];
                            my $lastchar = substr($workdir,-1);
                            if($lastchar ne "\/") {
                                $workdir.="\/";
                            }
                        }
                    }
                    default {
                        $arrayserial = $section;
                        my @values = split ("=",$configline);
                        if($configline =~ "subsystem_type") {
                            $arraytype = $values[1];
                            $arraytype =~ s/\s//g;
                        } elsif ($configline =~ "subsystem_name") {
                            $conf_storagename = uc $values[1];
                            $conf_storagename =~ s/\s//g;
                            $storage{$conf_storagename}{'serial'}=$arrayserial;
                            $storage{$conf_storagename}{'type'}=$arraytype;
                        } elsif ($configline =~ "service_run_every_hours") {
                            my $service_run_every_hours = $values[1];
                            $service_run_every_hours =~ s/\s//g;
                            $storage{$conf_storagename}{"service_run_every_hours"}=$service_run_every_hours;
                        } elsif ($configline =~ "service_run_minutes_after_hour") {
                            my $service_run_minutes_after_hour = $values[1];
                            $service_run_minutes_after_hour =~ s/\s//g;
                            $storage{$conf_storagename}{"service_run_minutes_after_hour"}=$service_run_minutes_after_hour;
                        }
                    }
                }
            }
        }
    }
}

# Sub to set all default if they are overwritten with individual values for each array

sub setdefaultsforarray {

    my $arraytosetdefault = $_[0];

    if(defined $storage{$arraytosetdefault}{"service_run_every_hours"}) {
            $runeveryhours = $storage{$arraytosetdefault}{"service_run_every_hours"};
    }
    if(defined $storage{$arraytosetdefault}{"service_run_minutes_after_hour"}) {
            $minafterfullhours = $storage{$arraytosetdefault}{"service_run_minutes_after_hour"};
    }
}

# sub to reload systemctl daemon after changes to service files

sub reloadsystemctl {
    console("Reloading systemctl daemon...");
    my $rc = system('systemctl daemon-reload');
    if($rc != 0) {
        console("Reload of systemctl daemon with command systemctl daemon-reload was not successful! Please ivenstigate!");
    } else {
        console("Reload was done successful!");
    }
}

# sub will register services based on storage array name or ALL storage systems

sub registerservice {
    my $storagename = $_[0];
    if($storagename eq 'ALL') {
        foreach my $storagesystem (sort keys %storage) {
            registerservice($storagesystem);
        }
    } else {
        if(!$realtime) {
            if(!defined $storage{$storagename}) {
                console("Storagesystem ".$storagename." cannot be found of configuration file ".$conf." ! Please check storagename or configuration file!");
                exit(1);
            }
            setdefaultsforarray($storagename);
            console("Registering service for ".$storagename." (Type: ".$storage{$storagename}{'type'}." / S/N: ".$storage{$storagename}{'serial'}.")");
            my $servicefile = '/usr/lib/systemd/system/hds2graphite-'.$storagename.'.service';
            if(-f $servicefile) {
                console("There is already a service with the name hds2graphite-".$storagename." registerd. You can either start, stop or restart the service. For updates to servicefile please deregister and register again.");
            } else {

                my $sfh;
                open $sfh, '>', $servicefile or die "Can't open file: $!";

                print $sfh "[Unit]\n";
                print $sfh "Description=HDS2GRAPHITE Service for ".$storagename." (Type: ".$storage{$storagename}{'type'}." / S/N: ".$storage{$storagename}{'serial'}.")\n";
                print $sfh "Documentation=http://www.openiomon.org\n";
                print $sfh "Wants=network-online.target\n";
                print $sfh "After=network-online.target\n";
                print $sfh "After=go-carbon.service\n\n";
                print $sfh "[Service]\n";
                print $sfh "Environment=\"PERL5LIB=".$libdir."perl5/:".$libdir."perl5/x86_64-linux-thread-multi/:".join(":",@INC)."\"\n";
                print $sfh "User=".$serviceuser."\n";
                print $sfh "Group=".$servicegroup."\n";
                print $sfh "Type=notify\n";
                print $sfh "Restart=always\n";
                print $sfh "WatchdogSec=".$watchdog."\n";
                print $sfh "WorkingDirectory=".$workdir."\n";
                print $sfh "RuntimeDirectoryMode=0750\n";
                print $sfh "StandardOutput=".$stdoutopt."\n";
                print $sfh "StandardError=".$stderropt."\n";
                print $sfh "ExecStart=".$workdir."bin/hds2graphite-worker.pl\t\t\t\\\n";
                print $sfh "\t\t-conf ".$workdir."conf/hds2graphite.conf\t\\\n";
                print $sfh "\t\t-storagesystem ".$storagename."\t\t\t\t\\\n";
                print $sfh "\t\t-hours ".$runeveryhours."\t\t\t\t\t\\\n";
                print $sfh "\t\t-daemon\n\n";
                print $sfh "[Install]\n";
                print $sfh "WantedBy=multi-user.target\n";
                close($sfh);
                console("Servicefile: ".$servicefile." has been created!");
            }
        } else {
            if(!defined $storage{$storagename}) {
                console("Storagesystem ".$storagename." cannot be found in the realtime configuration file ".$realtime_conf." ! Please check storagename or configuration file!");
                exit(1);
            }
            console("Registering realtime service for ".$storagename." (Type: ".$storage{$storagename}{'type'}." / S/N: ".$storage{$storagename}{'serial'}.")");
                        my $servicefile = '/usr/lib/systemd/system/hds2graphite-rt-'.$storagename.'.service';
                        if(-f $servicefile) {
                                console("There is already a service with the name hds2graphite-rt-".$storagename." registerd. You can either start, stop or restart the service. For updates to servicefile please deregister and register again.");
                        } else {

                                my $sfh;
                                open $sfh, '>', $servicefile or die "Can't open file: $!";

                                print $sfh "[Unit]\n";
                                print $sfh "Description=HDS2GRAPHITE Realtime Service for ".$storagename." (Type: ".$storage{$storagename}{'type'}." / S/N: ".$storage{$storagename}{'serial'}.")\n";
                                print $sfh "Documentation=http://www.openiomon.org\n";
                                print $sfh "Wants=network-online.target\n";
                                print $sfh "After=network-online.target\n";
                                print $sfh "After=go-carbon.service\n\n";
                                print $sfh "[Service]\n";
                                print $sfh "Environment=\"PERL5LIB=".$libdir."perl5/:".$libdir."perl5/x86_64-linux-thread-multi/:".join(":",@INC)."\"\n";
                                print $sfh "User=".$serviceuser."\n";
                                print $sfh "Group=".$servicegroup."\n";
                                print $sfh "Type=notify\n";
                                print $sfh "Restart=always\n";
                                print $sfh "WatchdogSec=".$watchdog."\n";
                                print $sfh "WorkingDirectory=".$workdir."\n";
                                print $sfh "RuntimeDirectoryMode=0750\n";
                                print $sfh "StandardOutput=".$stdoutopt."\n";
                                print $sfh "StandardError=".$stderropt."\n";
                                print $sfh "ExecStart=".$workdir."bin/hds2graphite-realtime.pl\t\t\t\\\n";
                                print $sfh "\t\t-conf ".$workdir."conf/hds2graphite.conf\t\\\n";
                                print $sfh "\t\t-storagesystem ".$storagename."\n";
                                print $sfh "[Install]\n";
                                print $sfh "WantedBy=multi-user.target\n";
                                close($sfh);
                                console("Servicefile: ".$servicefile." has been created!");
            }
        }
    }
}

# sub will remove services based on storage array name or ALL storage systems

sub deregisterservice {
    my $storagename = $_[0];
    if($storagename eq 'ALL') {
                foreach my $storagesystem (sort keys %storage) {
                        deregisterservice($storagesystem);
                }
    } else {
        if(!$realtime) {
            console("Trying to deregister service for storagesystem ".$storagename."...");
            if(!-f '/usr/lib/systemd/system/hds2graphite-'.$storagename.'.service'){
                console("\tThere is no service registered for ".$storagename."! Nothing to do...");
                return(0);
            }
            service($storagename,'stop');
            service($storagename,'disable');
            unlink '/usr/lib/systemd/system/hds2graphite-'.$storagename.'.service';
            $log->debug("Executed unlink for file /usr/lib/systemd/system/hds2graphite-".$storagename.".service");
            console("Service for ".$storagename." has been deregistered!");
        } else {
            console("Trying to deregister realtime service for storagesystem ".$storagename."...");
                        if(!-f '/usr/lib/systemd/system/hds2graphite-rt-'.$storagename.'.service'){
                                console("\tThere is no realtime service registered for ".$storagename."! Nothing to do...");
                                return(0);
                        }
                        service($storagename,'stop');
                        service($storagename,'disable');
                        unlink '/usr/lib/systemd/system/hds2graphite-rt-'.$storagename.'.service';
                        $log->debug("Executed unlink for file /usr/lib/systemd/system/hds2graphite-rt".$storagename.".service");
                        console("Realtime service for ".$storagename." has been deregistered!");

        }
    }
}

# sub to perform action on service (e.g. start, stop, restart, enable, disable)

sub service {
    my $storagename = $_[0];
    my $action = $_[1];
    if($storagename eq 'ALL') {
                foreach my $storagesystem (sort keys %storage) {
                        service($storagesystem,$action);
                }
    } else {
        if(!$realtime) {
            console("Trying to ".$action." service for storagesystem ".$storagename."...");
            if(!-f '/usr/lib/systemd/system/hds2graphite-'.$storagename.'.service'){
                console("\tService cannot be found for storagesystem ".$storagename.". Please register service or correct defined storagesystem or verify configuration file!");
                return(0);
            }
            my $cmd = 'systemctl '.$action.' hds2graphite-'.$storagename.' > /dev/null 2>&1';
            $log->debug("Running system command: ".$cmd);
            my $rc = system($cmd);
            if($rc==0) {
                console("Service ".$action."ed for storagesystem ".$storagename."!");
            } else {
                console("Failed to ".$action." service for storagesystem ".$storagename."! Please investigate!");
            }
        } else {
            console("Trying to ".$action." realtime service for storagesystem ".$storagename."...");
                        if(!-f '/usr/lib/systemd/system/hds2graphite-rt-'.$storagename.'.service'){
                                console("\tRealtime-service cannot be found for storagesystem ".$storagename.". Please register realtime service or correct defined storagesystem or verify configuration file!");
                                return(0);
                        }
                        my $cmd = 'systemctl '.$action.' hds2graphite-rt-'.$storagename.' > /dev/null 2>&1';
                        $log->debug("Running system command: ".$cmd);
                        my $rc = system($cmd);
                        if($rc==0) {
                                console("Realtime service ".$action."ed for storagesystem ".$storagename."!");
                        } else {
                                console("Failed to ".$action." realtime service for storagesystem ".$storagename."! Please investigate!");
                        }
        }
    }
}

# sub will report the status of a services based on storage array name or ALL storage systems

sub servicestatus {
    my $storagename = $_[0];
    if($storagename eq 'ALL') {
                foreach my $storagesystem (sort keys %storage) {
                       servicestatus($storagesystem);
                }
    } else {
        if(!$realtime) {
            $log->info("Gettings state and status of service for storagesystem ".$storagename);
            console($storagename.":");
            if(!-f '/usr/lib/systemd/system/hds2graphite-'.$storagename.'.service'){
                console("\tService cannot be found for storagesystem defined in configuration file. Please register service or correct confinguration file!");
                return(0);
            }
            my $querycmd = "systemctl status hds2graphite-".$storagename;
            my @result = `$querycmd`;
            my $state = "";
            foreach my $line (@result) {
                if ($line =~ "Loaded:") {
                    my @values = split(":",$line);
                    my $loaded = $values[1];
                    chomp($loaded);
                    console("\tLoaded:\t\t\t".$loaded);
                } elsif ($line =~ "Active:"){
                    my @values = split(":",$line);

                    for (my $i=1;$i<(scalar(@values));$i+=1) {
                        $state .= $values[$i].":";
                    }
                    chop($state);
                    chomp($state);
                    console("\tActive:\t\t\t".$state);
                } elsif ($line =~ "Status:"){
                    my @values = split(":",$line);
                    my $status = $values[1];
                    $status =~ s/\"//g;
                    chomp($status);
                    if($state =~ "inactive") {
                        console("\tLast status was:\t".$status);
                    } else {
                        console("\tStatus:\t\t\t".$status);
                    }
                }
            }
            my $runfile = $workdir."run/".$storage{$storagename}{'serial'}."_run.txt";
            if(!-f $runfile) {
                console("\tLast successful run:\t NEVER");
            } else {
                open my $runfh,'<',$runfile or die "Can't open file: $!";
                while(<$runfh>) {
                    my $line = $_;
                    my @values = split(" ",$line);
                    my $lastrunepoch = $values[0];
                    my $lastrunepochend = $values[2];
                    if($lastrunepoch == 0) {
                        console("\tLast successful run:\t NEVER");
                    } else {
                        my $timestringstart = strftime '%Y-%m-%d %H:%M:%S', localtime($lastrunepoch);
                        my $timestringend = strftime '%Y-%m-%d %H:%M:%S', localtime($lastrunepochend);
                        console("\tLast successful run:\t ".$timestringstart." - ".$timestringend."\n");
                    }
                }
            }
        } else {
            $log->info("Gettings state and status of realtime service for storagesystem ".$storagename);
                        console($storagename." (realtime service):");
                        if(!-f '/usr/lib/systemd/system/hds2graphite-rt-'.$storagename.'.service'){
                                console("\tService cannot be found for storagesystem defined in configuration file. Please register service or correct confinguration file!");
                                return(0);
                        }
                        my $querycmd = "systemctl status hds2graphite-rt-".$storagename;
                        my @result = `$querycmd`;
                        my $state = "";
                        foreach my $line (@result) {
                                if ($line =~ "Loaded:") {
                                        my @values = split(":",$line);
                                        my $loaded = $values[1];
                                        chomp($loaded);
                                        console("\tLoaded:\t\t\t".$loaded);
                                } elsif ($line =~ "Active:"){
                                        my @values = split(":",$line);

                                        for (my $i=1;$i<(scalar(@values));$i+=1) {
                                                $state .= $values[$i].":";
                                        }
                                        chop($state);
                                        chomp($state);
                                        console("\tActive:\t\t\t".$state);
                                } elsif ($line =~ "Status:"){
                                        my @values = split(":",$line);
                                        my $status = $values[1];
                                        $status =~ s/\"//g;
                                        chomp($status);
                                        if($state =~ "inactive") {
                                                console("\tLast status was:\t".$status);
                                        } else {
                                                console("\tStatus:\t\t\t".$status);
                                        }
                                }
                        }
        }

    }
}

sub preparecci {

    $log->info("Preparing CCI configuration for hds2graphite use!");
    $log->info("Installing CCI from image to ".$ccipath."HORCM\n");

    # change working directory to CCI dir
    

    if(! -f $cciimage) {
        $log->error("CCI image was not found at: ".$cciimage." Please check!");
        exit(1);
    }

    chdir($ccipath);
    my $cpiocmd = 'cpio -idmu <'.$cciimage;
    my $rc = system($cpiocmd);

    if($rc != 0) {
        $log->error("CPIO ended abnormaly with returncode: ".$rc);
        exit(1);
    }

    # create apath file
    
    my $apathfile = $ccipath.'HORCM/usr/bin/.APATH';
    $log->info("Creating .APATH file in ".$apathfile);
    open my $fh, '>', $apathfile or die $!;
    close($fh);
    
    # change permission and ownership to openiomon user


    $log->info("Changing rights and ownership of the CCI path ".$ccipath."HORCM to ".$serviceuser.":".$servicegroup);
    my $chowncmd = 'chown -R '.$serviceuser.":".$servicegroup." ".$ccipath."HORCM";
    $rc = system($chowncmd);
    if($rc != 0) {
        $log->error("CHOWN ended abnormaly with returncode: ".$rc);
        exit(1);
    }
    my $chmodcmd = 'chmod -R u+w '.$ccipath."HORCM";
    $rc = system($chmodcmd);
    if($rc != 0) {
        $log->error("CHMOD ended abnormaly with returncode: ".$rc);
        exit(1);
    }

}


# parse CLI parameters
parseCmdArgs();

$logfile = $logpath.$logname;

# Log4perl initialization
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

if($register ne "") {
    registerservice($register);
    reloadsystemctl();
}

if($deregister ne "") {
    deregisterservice($deregister);
    reloadsystemctl();
}

if($status ne "") {
    servicestatus($status);
}

if($start ne "") {
    service($start,'start');
}

if($stop ne "") {
    service($stop,'stop');
}

if($restart ne "") {
    service($restart,'restart');
}

if($enable ne "") {
    service($enable,'enable');
}

if($disable ne "") {
    service($disable,'disable');
}

if($preparecci ne "") {
    preparecci();
}
