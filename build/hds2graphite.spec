Summary: hds2graphite is a module of openiomon which is used to transfer statistics from the Hitachi block storage systems (G1x00, Gx00, VSP) to a graphite system to be able to display this statistics in Grafana.
Name: hds2graphite
Version: 0.3
prefix: /opt
Release: 2
URL: http://www.openiomon.org
License: GPL
Group: Applications/Internet
BuildRoot: %{_tmppath}/%{name}-root
Source0: hds2graphite-%{version}.tar.gz
BuildArch: x86_64
AutoReqProv: no
Requires: perl(JSON) perl(File::stat) perl(Getopt::Long) perl(IO::Socket::INET) perl(Log::Log4perl) perl(POSIX) perl(Time::HiRes) perl(Time::Local) perl(Time::Piece) perl(constant) perl(strict) perl(warnings) perl(version)



%description
Module for integration of Hitachi block storage (G1x00, Gx00, VSP) to Grafana. Data is pulled using Export Tool or HiAA or HTnM from Hitachi Vantara and send via plain text protocol to graphite / carbon cache systems.

%pre
getent group openiomon >/dev/null || groupadd -r openiomon
getent passwd openiomon >/dev/null || \
    useradd -r -g openiomon -d /home/openiomon -s /sbin/nologin \
    -c "openiomon module daemon user" openiomon
exit 0

%prep

%setup

%build

%install
rm -rf ${RPM_BUILD_ROOT}
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/arch/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/bin/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/metrics
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/templates
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/log/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/out/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/run/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/vsp/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/lib/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g1000/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g1500/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g400/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g600/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g800/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g900/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g700/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g370/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g350/
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 755 %{_builddir}/hds2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/hds2graphite/bin/
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/metrics/* ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/metrics
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/templates/* ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/templates
install -m 644 %{_builddir}/hds2graphite-%{version}/build/hds2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/hds2graphite
cp -a %{_builddir}/hds2graphite-%{version}/lib/* ${RPM_BUILD_ROOT}/opt/hds2graphite/lib/

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%defattr(644,openiomon,openiomon,755)
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/*.conf
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/metrics/*.conf
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/templates/*.txt
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/hds2graphite

%attr(755,openiomon,openiomon) /opt/hds2graphite
%attr(755,openiomon,openiomon) /opt/hds2graphite/*
%attr(755,openiomon,openiomon) /opt/hds2graphite/bin/*
%attr(755,openiomon,openiomon) /opt/hds2graphite/lib/perl5/
#%attr(755,root,root) /opt/hds2graphite/arch
#%attr(755,root,root) /opt/hds2graphite/log
#%attr(755,root,root) /opt/hds2graphite/out
#%attr(755,root,root) /opt/hds2graphite/run
#%attr(755,root,root) /opt/hds2graphite/vsp
#%attr(755,root,root) /opt/hds2graphite/lib
#%attr(755,root,root) /opt/hds2graphite/g1000
#%attr(755,root,root) /opt/hds2graphite/g1500
#%attr(755,root,root) /opt/hds2graphite/g400
#%attr(755,root,root) /opt/hds2graphite/g600
#%attr(755,root,root) /opt/hds2graphite/g800

%post
ln -s -f /opt/hds2graphite/bin/hds2graphite.pl /bin/hds2graphite

%changelog
* Thu Sep 19 2019 Timo Drach <timo.drach@openiomon.org>
- Preparation for release on github
- Added PERL5 systemd libraries
- Changes in logfilehandling for hds2graphite-realtime
* Mon Dec 03 2018 Timo Drach <timo.drach@cse-ub.de>
- Added support for Panama 2 Systeme
- Added support for Cache Partitions
- Added support for multi-vsm-GAD implementations
* Tue Aug 21 2018 Timo Drach <timo.drach@cse-ub.de>
- fixed minor issues
* Sun Aug 19 2018 Timo Drach <timo.drach@cse-ub.de>
- Changed config file struture
- added support for VSMs and GAD
- enhanded realtime gathering for HDS2GRAPHITE
- Changed package dependencies
* Mon May 21 2018 Timo Drach <timo.drach@cse-ub.de>
- Added realtime monitor for HDS2GRAPHITE
* Tue Mar 06 2018 Timo Drach <timo.drach@cse-ub.de>
- Changed some file permission to use user openiomon:openiomon
- rewritten creating of horcm.conf files
* Tue Jan 09 2018 Timo Drach <timo.drach@cse-ub.de>
- Added support for dropping service messages from syslog
* Tue Jan 02 2018 Timo Drach <timo.drach@cse-ub.de>
- Added creation of service user openiomon and changed file ownership
- Added logrotate file to build process
* Sat Dec 09 2017 Timo Drach <timo.drach@cse-ub.de
- Added support for config files in RPM-packge for go-carbon, metric and template configfiles.
* Wed Nov 22 2017 Timo Drach <timo.drach@cse-ub.de>
- Initial version
