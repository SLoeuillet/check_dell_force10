#!/usr/bin/perl

# Health-check for Dell Force10/MXL switch stack
# (c) 2015 Stephane Loeuillet for Capensis/CGG
# v2015-10-12

use strict;
use warnings;

use Net::SNMP;
use Getopt::Long;
use Data::Dumper;

############################################################

my $hostname    = undef;
my $community   = undef;
my $version     = 'snmpv2c';
my $debug       = 0;
my $dcb         = 0;
my $thr_uptime  = 24 * 3600;
my $thr_mem     = 80;
my $thr_cpu_all = 80;

############################################################

GetOptions(
    "hostname|H=s"  => \$hostname,
    "version|v=s"   => \$version,
    "community|c=s" => \$community,
    "verbose|V=i"   => \$debug,
    "dcb|d=i"       => \$dcb,
    "thr_uptime=i"  => \$thr_uptime,
    "thr_mem=i"     => \$thr_mem,
    "thr_cpu=i"     => \$thr_cpu_all
) or die("Error in command line arguments\n");

my %thr_cpu = (
    '5Sec' => $thr_cpu_all,
    '1Min' => $thr_cpu_all,
    '5Min' => $thr_cpu_all
);

my $baseOID = '1.3.6.1.4.1.6027';
my %OIDs    = (
    'F10ETSSystemControl'      => '.3.15.3.2.1.1',    # 1=running/2=shutdown
    'F10ETSModuleStatus'       => '.3.15.3.2.1.2',    # 1=enabled/2=disabled
    'F10PFCSystemControl'      => '.3.15.3.3.1.1',    # 1=running/2=shutdown
    'F10PFCModuleStatus'       => '.3.15.3.3.1.2',    # 1=enabled/2=disabled
    'chNumStackUnits'          => '.3.19.1.1.1',      # ModuleNb
    'chStackUnitMgmtStatus'    => '.3.19.1.2.1.1.4',  # 1=mgmtUnit/2=standbyUnit
    'chStackUnitModelID'       => '.3.19.1.2.1.1.7',  # string
    'chStackUnitDescription'   => '.3.19.1.2.1.1.9',  # string
    'chStackUnitCodeVersion'   => '.3.19.1.2.1.1.10', # string
    'chStackUnitSerialNumber'  => '.3.19.1.2.1.1.12', # string
    'chStackUnitUpTime'        => '.3.19.1.2.1.1.13', # timeticks
    'chStackUnitServiceTag'    => '.3.19.1.2.1.1.34', # string
    'chStackUnitCpuUtil5Sec'   => '.3.19.1.2.8.1.2',  # %
    'chStackUnitCpuUtil1Min'   => '.3.19.1.2.8.1.3',  # %
    'chStackUnitCpuUtil5Min'   => '.3.19.1.2.8.1.4',  # %
    'chStackUnitMemUsageUtil'  => '.3.19.1.2.8.1.5',  # %
    'chSysStackPortLinkStatus' => '.3.19.1.2.5.1.4',  # Table
);
my %res = ();

my ( $session, $error ) = Net::SNMP->session(
    -hostname  => $hostname,
    -version   => $version,
    -community => $community
);

if ( $session && !$error ) {
    foreach my $table ( sort keys %OIDs ) {

        $res{$table} =
          $session->get_table( -baseoid => $baseOID . $OIDs{$table}, );

        my @subres = keys %{ $res{$table} };
        if ( $#subres eq 0 ) {
            $res{$table} = $res{$table}{ $subres[0] };
        }
        else {
            foreach my $sub (@subres) {
                my $newkey = $sub;
                $newkey =~ s/^$baseOID$OIDs{$table}\.//;
                $res{$table}{$newkey} = $res{$table}{$sub};
                delete $res{$table}{$sub};
            }
        }
    }
}

$session->close();

# print Dumper( \%res );

my $exit     = 0;
my $message  = "";
my @parts    = ();
my @perfdata = ();

if ($dcb) {
    if ( $res{'F10ETSSystemControl'} ne 1 ) {
        push @parts, 'ETSSystemControl shutdown';
        $exit = 2;
    }
    if ( $res{'F10ETSModuleStatus'} ne 1 ) {
        push @parts, 'ETSModuleStatus disabled';
        $exit = 2;
    }
    if ( $res{'F10PFCSystemControl'} ne 1 ) {
        push @parts, 'PFCSystemControl shutdown';
        $exit = 2;
    }
    if ( $res{'F10PFCModuleStatus'} ne 1 ) {
        push @parts, 'PFCModuleStatus disabled';
        $exit = 2;
    }
}
if ( $res{'chNumStackUnits'} lt 2 ) {
    push @parts, 'chNumStackUnits < 2';
    $exit = 2;
}

my $codeversion = '';
my %mgmtstatus  = ( "1" => 0, "2" => 0, "3" => 0, "4" => 0 );
my %intstatus   = ( "1" => 0, "2" => 0 );
for ( my $i = 1 ; $i <= $res{'chNumStackUnits'} ; $i++ ) {
    if ( !$codeversion ) { $codeversion = $res{'chStackUnitCodeVersion'}{$i}; }
    if ( $codeversion ne $res{'chStackUnitCodeVersion'}{$i} ) {
        push @parts, 'CodeVersion mismatch';
        $exit = 2;
    }
    if ( $res{'chStackUnitUpTime'}{$i} =~
        m/^(\d+) days?, (\d{2}):(\d{2}):(\d{2})\.(\d{2})/ )
    {
        my $time = ( $1 * 24 + $2 ) * 3600 + $3 * 60 + $4 + $5 / 100;
        if ( $time < $thr_uptime ) {
            push @parts, "UpTime[$i] : $res{'chStackUnitUpTime'}{$i}";
            $exit = 2;
        }
        $res{'chStackUnitUpTime'}{"d$i"} = $time;
    }
    else {
        push @parts, "UpTime[$i] : unknown format";
        $exit = 2;
        $res{'chStackUnitUpTime'}{"d$i"} = 0;
    }

    foreach my $type ( sort keys %thr_cpu ) {
        if ( $res{ 'chStackUnitCpuUtil' . $type }{$i} >= $thr_cpu{$type} ) {
            push @parts,
"CPU[$type][$i] : $res{'chStackUnitCpuUtil'.$type}{$i} >= $thr_cpu{$type}%";
            $exit = 2;
        }
    }

    if ( $res{'chStackUnitMemUsageUtil'}{$i} >= $thr_mem ) {
        push @parts,
          "Memory[$i] : $res{'chStackUnitMemUsageUtil'}{$i} >= $thr_mem%";
        $exit = 2;
    }

    $mgmtstatus{ $res{'chStackUnitMgmtStatus'}{$i} }++;
    if ( $res{'chStackUnitMgmtStatus'}{$i} == 4 ) {
        push @parts, "MgmtStatus[$i] : unassigned";
        $exit = 2;
    }

    foreach my $key ( sort keys %{ $res{'chSysStackPortLinkStatus'} } ) {
        if ( $key =~ m/^$i\.(\d+)/ ) {
            $key = $1;
            $intstatus{ $res{'chSysStackPortLinkStatus'}{"$i.$key"} }++;
            if ( $res{'chSysStackPortLinkStatus'}{"$i.$key"} == 2 ) {
                push @parts, "IntStatus[$i][$key] : down";
                $exit = 2;
            }
        }
    }
}
if ( $mgmtstatus{"1"} != 1 ) {
    push @parts, "MgmtStatus : " . $mgmtstatus{"1"} . "/1 mgmt";
}
if ( $mgmtstatus{"2"} != 1 ) {
    push @parts, "MgmtStatus : " . $mgmtstatus{"2"} . "/1 standby";
}

my $mgmtstatus_t =
  $mgmtstatus{1} + $mgmtstatus{2} + $mgmtstatus{3} + $mgmtstatus{4};
my $intstatus_t = $intstatus{1} + $intstatus{2};

push @perfdata, "units=$res{'chNumStackUnits'}";
push @perfdata, "mstatus_mgmt=$mgmtstatus{1};;;0;$mgmtstatus_t";
push @perfdata, "mstatus_standby=$mgmtstatus{2};;;0;$mgmtstatus_t";
push @perfdata, "mstatus_stack=$mgmtstatus{3};;;0;$mgmtstatus_t";
push @perfdata, "mstatus_unassigned=$mgmtstatus{4};;;0;$mgmtstatus_t";
push @perfdata, "int_status_up=$intstatus{1};;;0;$intstatus_t";
push @perfdata, "int_status_down=$intstatus{2};;;0;$intstatus_t";

for ( my $i = 1 ; $i <= $res{'chNumStackUnits'} ; $i++ ) {
    push @perfdata,
      "cpu$i\_5s=$res{'chStackUnitCpuUtil5Sec'}{$i}%;$thr_cpu_all;$thr_cpu_all";
    push @perfdata,
      "cpu$i\_1m=$res{'chStackUnitCpuUtil1Min'}{$i}%;$thr_cpu_all;$thr_cpu_all";
    push @perfdata,
      "cpu$i\_5m=$res{'chStackUnitCpuUtil5Min'}{$i}%;$thr_cpu_all;$thr_cpu_all";
    push @perfdata,
      "mem$i=$res{'chStackUnitMemUsageUtil'}{$i}%;$thr_mem;$thr_mem";
    push @perfdata,
        "uptime$i="
      . $res{'chStackUnitUpTime'}{"d$i"}
      . "s;$thr_uptime;$thr_uptime";
}
if ( $exit == 0 ) { $message = 'OK'; }
else              { $message .= join( ', ', @parts ); }

if ( $debug == 1 ) {
    my @debug = ();
    for ( my $i = 1 ; $i <= $res{'chNumStackUnits'} ; $i++ ) {
        my $deb = '';
        $deb .= "ModelId : $res{'chStackUnitModelID'}{$i} ";
        $deb .= "Description : $res{'chStackUnitDescription'}{$i} ";
        $deb .= "CodeVersion : $res{'chStackUnitCodeVersion'}{$i} ";
        $deb .= "SerialNumber : $res{'chStackUnitSerialNumber'}{$i} ";
        $deb .= "ServiceTag : $res{'chStackUnitServiceTag'}{$i} ";
        $deb .= "Uptime : $res{'chStackUnitUpTime'}{$i} ";
        $deb .= "MgmtStatus : $res{'chStackUnitMgmtStatus'}{$i} ";
        $deb .= "CpuUtil 5s : $res{'chStackUnitCpuUtil5Sec'}{$i} ";
        $deb .= "CpuUtil 1m : $res{'chStackUnitCpuUtil1Min'}{$i} ";
        $deb .= "CpuUtil 5m : $res{'chStackUnitCpuUtil5Min'}{$i} ";
        $deb .= "MemUtil : $res{'chStackUnitMemUsageUtil'}{$i}";
        push @debug, $deb;
    }

    $message .=
      ' // ' . "$res{'chNumStackUnits'} [" . join( '],[', @debug ) . ']';
}

$message .= '|' . join( ' ', @perfdata );

print "$message\n";
exit($exit);
