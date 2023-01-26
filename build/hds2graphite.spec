Summary:    hds2graphite is a module of openiomon which is used to transfer statistics from the Hitachi block storage systems (G1x00, Gx00, VSP) to a graphite system to be able to display this statistics in Grafana.
Name:       hds2graphite
Version:    0.4.2
prefix:     /opt
Release:    1
License:    GPL
Group:      Applications/Internet
BuildArch:  noarch
AutoReqProv: no
URL:        https://github.com/openiomon/%{name}
Source0:    https://github.com/openiomon/%{name}/%{name}-%{version}.tar.gz
Requires:   perl(File::stat) perl(Getopt::Long) perl(IO::Socket::INET) perl(IO::Socket::UNIX) perl(JSON) perl(Log::Log4perl) perl(LWP::UserAgent) perl(POSIX) perl(Time::HiRes) perl(Time::Local) perl(Time::Piece) perl(constant) perl(strict) perl(warnings) perl(version)


%description
Module for integration of Hitachi block storage (5x00, G1x00, Gx00, VSP) to Grafana. Data is pulled using Export Tool or HiAA or HTnM from Hitachi Vantara and send via plain text protocol to graphite / carbon cache systems.

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
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/dashboards/graphite
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/dashboards/prometheus
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/log/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/out/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/run/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/vsp/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g1000/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g1500/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g350/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g370/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g400/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g600/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g700/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g800/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/g900/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/5100/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/5200/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/5500/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/5600/
mkdir -p ${RPM_BUILD_ROOT}/opt/hds2graphite/cci/
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 755 %{_builddir}/hds2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/hds2graphite/bin/
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/*.example ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/metrics/* ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/metrics
install -m 644 %{_builddir}/hds2graphite-%{version}/conf/templates/* ${RPM_BUILD_ROOT}/opt/hds2graphite/conf/templates
install -m 644 %{_builddir}/hds2graphite-%{version}/build/hds2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/hds2graphite
cp -a %{_builddir}/hds2graphite-%{version}/dashboards/graphite/*.json ${RPM_BUILD_ROOT}/opt/hds2graphite/dashboards/graphite
cp -a %{_builddir}/hds2graphite-%{version}/dashboards/prometheus/*.json ${RPM_BUILD_ROOT}/opt/hds2graphite/dashboards/prometheus

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%defattr(644,openiomon,openiomon,755)
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/*.conf
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/metrics/*.conf
%config(noreplace) %attr(644,openiomon,openiomon) /opt/hds2graphite/conf/templates/*.txt
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/hds2graphite

%attr(755,openiomon,openiomon) /opt/hds2graphite
%attr(755,openiomon,openiomon) /opt/hds2graphite/bin/*

%post
ln -s -f /opt/hds2graphite/bin/hds2graphite.pl /bin/hds2graphite

%changelog
* Thu Jan 26 2023 Timo Drach <timo.drach@openiomon.org>
- do not set executable permission for all files
* Mon Jan 23 2023 Timo Drach <timo.drach@openiomon.org>
- corrected package versioning scheme
* Wed Jan 18 2023 Timo Drach <timo.drach@openiomon.org>
- Removed Systemd Perl Libs
- added dependency to Perl IO::Socket::UNIX
- changed arch to noarch
* Mon Sep 23 2019 Timo Drach <timo.drach@openiomon.org>
- Cleanup or perl libraries and dependencies
* Thu Sep 19 2019 Timo Drach <timo.drach@openiomon.org>
- Added PERL5 systemd libraries
* Sun Aug 19 2018 Timo Drach <timo.drach@cse-ub.de>
- Changed package dependencies
* Tue Mar 06 2018 Timo Drach <timo.drach@cse-ub.de>
- Changed some file permission to use user openiomon:openiomon
* Tue Jan 02 2018 Timo Drach <timo.drach@cse-ub.de>
- Added creation of service user openiomon and changed file ownership
- Added logrotate file to build process
* Sat Dec 09 2017 Timo Drach <timo.drach@cse-ub.de
- Added support for config files in RPM-packge for go-carbon, metric and template configfiles.
* Wed Nov 22 2017 Timo Drach <timo.drach@cse-ub.de>
- Initial version
