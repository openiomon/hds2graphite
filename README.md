# Table of Contents

* [Features](#features)
* [Installation](#installation)
* [Configuration](#configuration)
* [Changelog](#changelog)
* [Disclaimer](#disclaimer)

# hds2graphite

A tool to retrieve Hitachi Block Storage performance counters via Hitachi Export Tool (historical) or Hitachi Tuning Manager (HTNM) / Infrastructure Analytics Advisor (HIAA) / Ops Center Analyzer (realtime) and write them to a Carbon/Graphite backend.
* Written in Perl
* tested on RHEL / CentOS 7 & 8
* RPM package available

## Features
* Add one or more storage system instances and/or virtual storage machines
* configurable retrieval time for historical performance data
* configurable metrics
* Workers run as systemd service
* thottling to prevent overloading carbon backends
* runs in non-root environment as service user

## Installation
Install on RHEL via RPM package: `yum install hds2graphite-0.x-x.rpm`

Perl dependencies that are not available in RHEL / CentOS repositories:
* Log::Log4perl (RPM perl-Log-Log4perl available in [EPEL repository](https://fedoraproject.org/wiki/EPEL))

For other Linux distributions you can just clone the repository. Default installation folder is `/opt/hds2graphite`. The service operates with a user called "openiomon"

For installation of Hitachi Command Control Interface (CCI) needed for non-realtime-performance-data copy the the CCI CPIO archive to `/opt/hds2graphite/cci/` and run `hds2graphite -preparecci`.

**SElinux Note**
If you use SElinux in enforcing mode, you need to set the context for the log directory manually. Otherwise logrotate will fail. Use the following commands:
```
semanage fcontext -a -t var_log_t /opt/hds2graphite/log(/.*)?
restorecon /opt/hds2graphite/log/
```

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

* Specify the connection to your Tuning Manager / Infrastructure Analytics Advisor / Ops Center Analyzer
`# Specify the parameters for HTNM or HIAA access. For Ops Center Analyzer use HIAA`  
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
Option to select the metric format  
graphite-dot - Classic graphite/carbon format, Example: "hds.perf.5600.NAME.metric"  
graphite-tag - Tag style format, tested with [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics), Example: "my_series;tag1=value1;tag2=value2"  
`metric_format = graphite-dot`

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
### 0.4.0
* Added support for graphite-tag format to be used with VirtoriaMetrics backend
* Added PromQL dashboards (tested with VictoriaMetrics)
* reworked dashboard import function
* Added support for VSP 5x00 machines
* Added support for RHEL 8
* removed metrics collection for counters marked "reserved" in the Ops Center Analyzer REST API documentation
* fixed realtime port_avg_response_rate not showing values
* realtime service will retry longer before failing
* log worker die message, thanks to user [NimVek](https://github.com/NimVek) for the suggestion
* removed dependency to Perl module Systemd::Daemon

### 0.3.4
* First public release

# Disclaimer
This source and the whole package comes without warranty. It may or may not harm your computer. Please use with care. Any damage cannot be related back to the author.

