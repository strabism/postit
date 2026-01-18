#!/usr/bin/perl
use strict;
use warnings;
use XML::LibXML;

my $file = shift or die "Usage: $0 deftable.xml\n";

my $dom = XML::LibXML->load_xml(location => $file);

# --- Folder ---
my ($folder) = $dom->findnodes('//FOLDER')
    or die "No FOLDER found\n";

my $datacenter   = $folder->getAttribute('DATACENTER') // '';
my $folder_name  = $folder->getAttribute('FOLDER_NAME') // '';
my $order_method = $folder->getAttribute('FOLDER_ORDER_METHOD') // 'manual order';

# --- Collections ---
my (%tasktypes, %appl_types, %nodeids);
my (%inconds, %outconds, %doconds);
my (%libmemsym, %shout_dest, %calendars, %quantitative, %run_as);
my @odate_stat_hits;
my @check_srv_usage_content;
my @jobs_sensitive_content = ("JOBNAME,CMDLINE,TASKTYPE\n");

sub print_section {
    my ($name, $content_ref) = @_;
    print "\n========\n";
    print "$name\n";
    print "========\n";
    print @$content_ref if $content_ref;
}

# =========================
# Parcours des jobs
# =========================
foreach my $job ($dom->findnodes('//JOB')) {

    my $jobname      = $job->getAttribute('JOBNAME')       // '';
    my $run_as_val   = $job->getAttribute('RUN_AS')       // '';
    my $tasktype     = $job->getAttribute('TASKTYPE')     // '';
    my $appl_type    = $job->getAttribute('APPL_TYPE')    // '';
    my $nodeid       = $job->getAttribute('NODEID')       // '';
    my $sub_app      = $job->getAttribute('SUB_APPLICATION') // '';

    $tasktypes{$tasktype}   = 1 if $tasktype;
    $appl_types{$appl_type} = 1 if $appl_type;
    $nodeids{$nodeid}       = 1 if $nodeid;
    $run_as{$run_as_val}    = 1 if $run_as_val;

    # INCOND / OUTCOND
    foreach my $n ($job->findnodes('.//INCOND | .//OUTCOND')) {
        my $name = $n->getAttribute('NAME');
        next unless $name;
        $n->nodeName eq 'INCOND' ? $inconds{$name} = 1 : $outconds{$name} = 1;
    }

    # DOCOND
    foreach my $d ($job->findnodes('.//DOCOND')) {
        my $name = $d->getAttribute('NAME');
        $doconds{$name} = 1 if $name;
    }

    # LIBMEMSYM
    foreach my $v ($job->findnodes('.//VARIABLE[@NAME="%%LIBMEMSYM"]')) {
        my $val = $v->getAttribute('VALUE');
        $libmemsym{$val} = 1 if $val;
    }

    # SHOUT DEST
    foreach my $s ($job->findnodes('.//SHOUT')) {
        my $dest = $s->getAttribute('DEST');
        $shout_dest{$dest} = 1 if $dest;
    }

    # CALENDARS
    foreach my $c (qw(DAYSCAL MONTHSCAL WEEKSCAL)) {
        my $val = $job->getAttribute($c);
        $calendars{$val} = 1 if $val;
    }

    # QUANTITATIVE RESOURCES
    foreach my $q ($job->findnodes('.//QUANTITATIVE')) {
        my $name = $q->getAttribute('NAME');
        $quantitative{$name} = 1 if $name;
    }

    # ODATE="STAT"
    foreach my $n ($job->findnodes('.//*[@ODATE="STAT"]')) {
        my $line = $n->toString();
        $line =~ s/\n/ /g;
        $line =~ s/"/""/g;
        push @odate_stat_hits, [$jobname, "\"$line\""];
    }

    # JOBS_USER_CTM
    if ($run_as_val eq 'ctmag900' || $run_as_val eq 'ctmag901') {
        my $cmd = $job->getAttribute('CMDLINE') // '';
        $cmd =~ s/"/""/g;
        push @jobs_sensitive_content, "$jobname,\"$cmd\",$tasktype\n";
    }

    # CHECK_SRV_USAGE (ordre SUB_APPLICATION, JOBNAME, CMDLINE)
    if ($tasktype ne 'Dummy' && (!$nodeid || $nodeid eq 'SRV_PRIMAIRE' || $nodeid eq 'SRV_BACKUP')) {
        my $cmd = $job->getAttribute('CMDLINE') // '';
        $cmd =~ s/"/""/g;
        push @check_srv_usage_content, "\"$sub_app\",\"$jobname\",\"$cmd\"\n";
    }
}

# =========================
# Impression des sections
# =========================

# 1. FOLDER
my @folder_content = ("DATACENTER,FOLDER_NAME,FOLDER_ORDER_METHOD\n$datacenter,$folder_name,$order_method\n");
print_section("SECTION,FOLDER", \@folder_content);

# 2. JOBS_USER_CTM
print_section("SECTION,JOBS_USER_CTM", \@jobs_sensitive_content);

# 3. TASK_TYPES
my @tasktypes_content;
if (%tasktypes || %appl_types) {
    push @tasktypes_content, "TYPE,VALUE\n";
    push @tasktypes_content, map { "TASKTYPE,$_ \n" } sort keys %tasktypes;
    push @tasktypes_content, map { "APPL_TYPE,$_ \n" } sort keys %appl_types;
}
print_section("SECTION,TASK_TYPES", \@tasktypes_content);

# 4. NODEID_HOSTGRP
my @nodeids_content;
if (%nodeids) {
    push @nodeids_content, "NODEID\n";
    push @nodeids_content, map { "$_\n" } sort keys %nodeids;
}
print_section("SECTION,NODEID_HOSTGRP", \@nodeids_content);

# 5. RUN_AS
my @runas_content;
if (%run_as) {
    push @runas_content, "VALUE\n";
    push @runas_content, map { "$_\n" } sort keys %run_as;
}
print_section("SECTION,RUN_AS", \@runas_content);

# 6. CHECK_SRV_USAGE
my @check_srv_usage;
if (@check_srv_usage_content) {
    push @check_srv_usage, "SUB_APPLICATION,JOBNAME,CMDLINE\n";
    push @check_srv_usage, @check_srv_usage_content;
}
print_section("SECTION,CHECK_SRV_USAGE", \@check_srv_usage);

# 7. DEPENDENCIES (simplifié)
my @dependencies_content;
push @dependencies_content, "TYPE,NAME\n";

# PROBLEMATIC_IN : INCOND qui n'existe ni dans OUTCOND ni DOCOND
foreach my $cond (sort keys %inconds) {
    next if exists $outconds{$cond} || exists $doconds{$cond};
    push @dependencies_content, "PROBLEMATIC_IN,$cond\n";
}

# PROBLEMATIC_OUT : OUTCOND qui n'existe ni dans INCOND ni DOCOND
foreach my $cond (sort keys %outconds) {
    next if exists $inconds{$cond} || exists $doconds{$cond};
    push @dependencies_content, "PROBLEMATIC_OUT,$cond\n";
}

print_section("SECTION,DEPENDENCIES", \@dependencies_content);

# 8. ODATE_STAT
my @odate_content;
if (@odate_stat_hits) {
    push @odate_content, "JOBNAME,XML_LINE\n";
    push @odate_content, map { join(",", @$_) . "\n" } @odate_stat_hits;
}
print_section("SECTION,ODATE_STAT", \@odate_content);

# 9. LIBMEMSYM
my @libmem_content;
push @libmem_content, "VALUE\n" if %libmemsym;
push @libmem_content, map { "$_\n" } sort keys %libmemsym;
print_section("SECTION,LIBMEMSYM", \@libmem_content);

# 10. SHOUT_DEST
my @shout_content;
push @shout_content, "DEST\n" if %shout_dest;
push @shout_content, map { "$_\n" } sort keys %shout_dest;
print_section("SECTION,SHOUT_DEST", \@shout_content);

# 11. CALENDARS
my @cal_content;
push @cal_content, "CALENDAR\n" if %calendars;
push @cal_content, map { "$_\n" } sort keys %calendars;
print_section("SECTION,CALENDARS", \@cal_content);

# 12. QUANTITATIVE_RESOURCES
my @quant_content;
push @quant_content, "NAME\n" if %quantitative;
push @quant_content, map { "$_\n" } sort keys %quantitative;
print_section("SECTION,QUANTITATIVE_RESOURCES", \@quant_content);

print "\n";
