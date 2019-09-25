# Table of Contents

* [Features](#features)
* [Installation](#installation)
* [Configuration](#configuration)
* [Changelog](#changelog)
* [Disclaimer](#disclaimer)

# hds2graphite

A tool to retrieve Hitachi Block Storage Performance counters via Hitachi Export Tool or Hitachi Tuning Manager (HTNM) / Infrastructure Analytics Advisor (HIAA) and write them to a Carbon/Graphite backend.
* Written in Perl.
* tested on RHEL / CentOS 7
* RPM package available

## Features
* Add one or more storage system instances
* configurable retrieval time
* configurable metrics
* Workers run as systemd service

## Installation
Install on RHEL via RPM package: `yum install hds2graphite-0.x-x.rpm`

Perl dependencies that are not available in RHEL / CentOS 7 repositories:
* Log::Log4perl (RPM perl-Log-Log4perl available in [EPEL repository](https://fedoraproject.org/wiki/EPEL))
* Systemd::Daemon (included in the release package, [view in CPAN](https://metacpan.org/pod/Systemd::Daemon))

For other Linux distributions you can just clone the repository. Default installation folder is `/opt/hds2graphite`. The service operates with a user called "openiomon"

For installation of Hitachi Command Control Interface (CCI) needed for non-realtime-performance-data copy the the CCI CPIO archive to `/opt/hds2graphite/cci/` and run `hds2graphite -preparecci`.

## Configuration
1. Edit the `/opt/hds2graphite/conf/hds2graphite.conf`, settings you have to edit for a start:

* Specifiy the connection parameter to the storage system  
`# Specify each storage system that should be monitored through hds2graphite`  
`# Each specification block starts with [serial]`  
`[12345]`  
`subsystem_type = g1500`  
`subsystem_name = VSP1`  
`svp_ip = 10.1.1.10`  
`cci_instance_number = 10`  
`metric_configruation = /opt/hds2graphite/conf/metrics/g1500_metrics.conf`  
`exporttool_template = /opt/hds2graphite/conf/templates/g1500_template.txt`  
`# if virtual devices with GAD should monitored on top of the phyical devices specify the VSM for virtual serial number 99999 and VSM name GAD_VSM_1 and the GAD Resource-Group-ID`  
`# gad_vsm = serial, type, vsm name, resource group id`  
`gad_vsm = 99999,g1500,GAD_VSM_1,1`  

* Specify the connection to your Tuning Manager / Infrastructure Analytics Advisor  
`# Specify the parameters for HTNM or HIAA access.`  
`# realtime_application can be HTNM or HIAA`  
`[realtime]`  
`realtime_application = HTNM`  
`realtime_api_host = myhtnmserver.corp.com`  
`realtime_api_port = 22016`  
`realtime_api_proto = https`  
`realtime_api_user = HTNMUSER`  
`realtime_api_passwd = HTNMPASSWD`  

* Download Export Tool (when you want to use Export Tool instead of HTNM / HIAA)  
Download the "Customer Tools CD" for your machine type from Hitachi Support and extract the Export Tool to `/opt/hds2grapghite/gx00`. The Subfolder should match your machine type.

* Specify the user and password for CCI (when using Export Tool instead of HTNM / HIAA)  
`# Specify the username and password for raidcom queries. The user used by Export Tool is defined in the Export Tool command.txt file.`  
`# This user can optionally be specified for each storage system and will overwrite the global user for the array`  
`[cci]`  
`cci_user = CCI_USERNAME`  
`cci_passwd = CCI_PASSWORD`  

* Specify the connection to your carbon/graphite backend  
`[graphite]`  
`host = 127.0.0.1`  
`port = 2003`  

2. Create a service  
When using Export Tool: `/opt/hds2graphite/bin/hds2graphite.pl -register <subsystem name>`  
When using HTNM / HIAA: `/opt/hds2graphite/bin/hds2graphite.pl -register <subsystem name> -realtime`

3. Enable the service
When using Export Tool: `/opt/hds2graphite/bin/hds2graphite.pl -enable <subsystem name>`  
When using HTNM / HIAA: `/opt/hds2graphite/bin/hds2graphite.pl -enable <subsystem name> -realtime`

4. Start the service
When using Export Tool: `/opt/hds2graphite/bin/hds2graphite.pl -start <subsystem name>`  
When using HTNM / HIAA: `/opt/hds2graphite/bin/hds2graphite.pl -start <subsystem name> -realtime`

## Changelog
### 0.3
* First public release

# Disclaimer
This source and the whole package comes without warranty. It may or may not harm your computer. Please use with care. Any damage cannot be related back to the author.

