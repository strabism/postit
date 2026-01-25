#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);
use POSIX qw(strftime);
use XML::LibXML;

# ----------------------------------------------------------------------
# Paramètres : datacenters à filtrer pour les pools
# ----------------------------------------------------------------------
my @DC_FILTER = @ARGV;
if (!@DC_FILTER) {
    die "Usage: $0 <DATACENTER1> [DATACENTER2 ...]\n";
}

sub archive_matches_dc {
    my ($file) = @_;
    for my $dc (@DC_FILTER) {
        return 1 if $file =~ /\Q$dc\E/;
    }
    return 0;
}

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
my $BASE_DIR        = '/workspace/Analyse';
my $ANALYSE_DIR     = "$BASE_DIR/analyse";
my $TMP_DIR         = "$ANALYSE_DIR/tmp";
my $POOL_PROD_DIR   = "$BASE_DIR/pool_prod";
my $POOL_HPROD_DIR  = "$BASE_DIR/pool_horsprod";

# ----------------------------------------------------------------------
# Utilitaires
# ----------------------------------------------------------------------
sub run_cmd {
    my ($cmd) = @_;
    my $rc = system($cmd);
    die "Erreur commande: $cmd (rc=$rc)\n" if $rc != 0;
}

sub purge_tmp {
    print "\nNettoyage du répertoire TMP...\n";
    if (-d $TMP_DIR) {
        opendir(my $dh, $TMP_DIR) or die "Impossible d'ouvrir $TMP_DIR: $!";
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\.\.?$/;
            remove_tree("$TMP_DIR/$entry");
        }
        closedir($dh);
    }
    print "TMP nettoyé.\n";
}

sub extract_archive {
    my ($archive, $dest_root) = @_;

    my $base = basename($archive);
    $base =~ s/\.(tar|tar\.gz|tgz)$//i;
    my $dest = "$dest_root/$base";

    if (! -d $dest) {
        remove_tree($dest) if -e $dest;
        make_path($dest);

        if ($archive =~ /\.tar\.gz$|\.tgz$/i) {
            run_cmd("tar xzf '$archive' -C '$dest'");
        } else {
            run_cmd("tar xf '$archive' -C '$dest'");
        }
    }

    my @subdirs = grep { -d $_ } glob("$dest/*");
    die "Impossible de trouver le répertoire racine dans $dest\n" unless @subdirs;

    return $subdirs[0];
}

sub read_file {
    my ($file) = @_;
    return '' unless -f $file;
    open my $fh, '<', $file or die "Impossible de lire $file: $!\n";
    local $/ = undef;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub read_lines {
    my ($file) = @_;
    return () unless -f $file;
    open my $fh, '<', $file or die "Impossible de lire $file: $!\n";
    my @l = map { chomp; $_ } <$fh>;
    close $fh;
    return @l;
}

sub parse_index_toc {
    my ($file) = @_;
    my %info;
    return %info unless -f $file;

    for my $l (read_lines($file)) {
        next if $l =~ /^\s*#/;
        next unless $l =~ /=/;
        my ($k,$v) = split(/=/, $l, 2);
        $k =~ s/\s+//g;
        $v =~ s/^\s+|\s+$//g;
        $info{$k} = $v;
    }
    return %info;
}

sub split_colon_list {
    my ($v) = @_;
    return () unless defined $v && $v ne '';
    return map { s/^\s+|\s+$//g; $_ } split(/:/, $v);
}

sub parse_quantitative_idx {
    my ($file) = @_;
    my @names;
    for my $l (read_lines($file)) {
        next if $l =~ /^\s*$/;
        my ($name) = split(/;/, $l);
        push @names, $name if defined $name && $name ne '';
    }
    return @names;
}

sub parse_nodeids {
    my ($file) = @_;
    return grep { $_ ne '' } read_lines($file);
}

sub parse_nodegroups {
    my ($file) = @_;
    my (@hg, @nid);
    for my $l (read_lines($file)) {
        next if $l =~ /^\s*$/;
        my @p = split(/:/, $l);
        my $h = shift @p;
        push @hg, $h if defined $h && $h ne '';
        push @nid, grep { $_ ne '' } @p;
    }
    return (\@hg, \@nid);
}

sub parse_conditions_from_schedtable {
    my ($file) = @_;
    my %c;
    return keys %c unless -f $file;

    for my $l (read_lines($file)) {
        next unless $l =~ /(INCOND|OUTCOND|DOCOND)/;
        while ($l =~ /NAME="([^"]+)"/g) {
            $c{$1} = 1;
        }
    }
    return keys %c;
}

sub get_root_for_pool_archive {
    my ($archive, $pool) = @_;
    my $dest = "$TMP_DIR/$pool";
    make_path($dest) unless -d $dest;
    return extract_archive($archive, $dest);
}

sub get_archive_identity {
    my ($root) = @_;
    my %idx = parse_index_toc("$root/.index.toc");
    return join('|',
        $idx{'EXP_TABLE'} // '',
        $idx{'EXP_DC'}    // '',
        $idx{'EXP_SIG'}   // ''
    );
}

sub find_quantitative_matches {
    my ($file, $patterns) = @_;
    return () unless -f $file;

    my $c = read_file($file);
    my %seen;

    for my $q (@$patterns) {
        next unless $q;
        my $re = quotemeta($q);

        if ($c =~ /<\s*QUANTITATIVE\s+NAME\s*=\s*"${re}"/) {
            $seen{$q} = 1;
        }
    }

    return sort keys %seen;
}

sub find_matches_in_two_files {
    my ($file1, $file2, $patterns) = @_;
    my $c1 = -f $file1 ? read_file($file1) : '';
    my $c2 = -f $file2 ? read_file($file2) : '';
    my %seen;

    for my $p (@$patterns) {
        next unless $p;
        my $re = quotemeta($p);
        if ($c1 =~ /\b$re\b/i || $c2 =~ /\b$re\b/i) {
            $seen{$p} = 1;
        }
    }

    return sort keys %seen;
}

sub find_condition_matches {
    my ($file, $patterns) = @_;
    return () unless -f $file;

    my $c = read_file($file);
    my %seen;

    for my $p (@$patterns) {
        next unless $p;
        my $re = quotemeta($p);

        if ($c =~ /NAME="$re"/) {
            $seen{$p} = 1;
        }
    }

    return sort keys %seen;
}

# Sortie console + log
sub out {
    my ($fh, $msg) = @_;
    print $msg;
    print $fh $msg;
}
# ----------------------------------------------------------------------
# Analyse d'une archive
# ----------------------------------------------------------------------
sub analyse_archive {
    my ($archive) = @_;

    my $root = extract_archive($archive, $TMP_DIR);
    my %idx = parse_index_toc("$root/.index.toc");
    my $current_id = get_archive_identity($root);

    my $ts = strftime("%Y-%m-%d_%Hh%M", localtime());
    my $logfile = "$ANALYSE_DIR/$idx{EXP_TABLE}-$idx{EXP_DC}-$ts.log";

    open my $LOG, '>', $logfile or die "Impossible d'écrire $logfile: $!";

    out($LOG, "\n============================================================\n");
    out($LOG, "Analyse de l'archive: $archive\n");
    out($LOG, "============================================================\n");

    out($LOG, "[1] Présentation de la table\n");
    out($LOG, "  - Archive      : $archive\n");
    out($LOG, "  - EXP_TABLE    : $idx{EXP_TABLE}\n");
    out($LOG, "  - EXP_DT       : $idx{EXP_DT}\n");
    out($LOG, "  - EXP_DC       : $idx{EXP_DC}\n");
    out($LOG, "  - EXP_HOST     : $idx{EXP_HOST}\n");
    out($LOG, "  - EXP_JOBS     : $idx{EXP_JOBS}\n");

    my @cals = split_colon_list($idx{'EXP_CAL'});
    my @libs = split_colon_list($idx{'EXP_LIB'});
    my @quant = parse_quantitative_idx("$root/res/quantitative.idx");
    my @nid1  = parse_nodeids("$root/nod/NODEIDS.dat");
    my ($hg_ref, $nid2_ref) = parse_nodegroups("$root/nod/NODEGROUP.dat");

    my %nid_all = map { $_ => 1 } (@nid1, @$nid2_ref);
    my @all_nid = sort keys %nid_all;
    my @hostgroups = @$hg_ref;

    my $sched_file = "$root/schedtable.xml";
    my $folder_order_method = 'manual order';
    my (%shout_dest, %run_as, %quantitative_xml);
    my @odate_stat_hits;
    my @jobs_user_ctm;
    my @check_srv_usage;
    my @agt8_hits;
    my @agt9_hits;
    my %tasktypes;
    my %appl_types;

    if (-f $sched_file) {
        my $dom = XML::LibXML->load_xml(location => $sched_file);

        if (my ($folder) = $dom->findnodes('//FOLDER')) {
            my $val = $folder->getAttribute('FOLDER_ORDER_METHOD');
            $folder_order_method = $val // 'manual order';
        }

        foreach my $job ($dom->findnodes('//JOB')) {
            my $jobname   = $job->getAttribute('JOBNAME')          // '';
            my $run_as_v  = $job->getAttribute('RUN_AS')           // '';
            my $tasktype  = $job->getAttribute('TASKTYPE')         // '';
            my $appl_type = $job->getAttribute('APPL_TYPE')        // '';
            $tasktypes{$tasktype} = 1 if $tasktype;
            $appl_types{$appl_type} = 1 if $appl_type;
            my $nodeid    = $job->getAttribute('NODEID')           // '';
            my $sub_app   = $job->getAttribute('SUB_APPLICATION')  // '';
            my $cmdline   = $job->getAttribute('CMDLINE')          // '';

            $run_as{$run_as_v} = 1 if $run_as_v;

            foreach my $s ($job->findnodes('.//SHOUT')) {
                my $dest = $s->getAttribute('DEST');
                $shout_dest{$dest} = 1 if $dest;
            }

            foreach my $q ($job->findnodes('.//QUANTITATIVE')) {
                my $name = $q->getAttribute('NAME');
                $quantitative_xml{$name} = 1 if $name;
            }

            foreach my $n ($job->findnodes('.//*[@ODATE="STAT"]')) {
                my $line = $n->toString();
                $line =~ s/\n/ /g;
                $line =~ s/"/""/g;
                push @odate_stat_hits, [$jobname, "\"$line\""];
            }

            if ($run_as_v eq 'ctmag900' || $run_as_v eq 'ctmag901') {
                my $cmd = $cmdline;
                $cmd =~ s/"/""/g;
                push @jobs_user_ctm, {
                    SUB_APPLICATION => $sub_app,
                    JOBNAME         => $jobname,
                    TASKTYPE        => $tasktype,
                    APPL_TYPE       => $appl_type,
                    CMDLINE         => $cmd,
                };
            }

            if ($tasktype ne 'Dummy' &&
                (!$nodeid || $nodeid eq 'SRV_PRIMAIRE' || $nodeid eq 'SRV_BACKUP')) {

                my $cmd = $cmdline;
                $cmd =~ s/"/""/g;
                push @check_srv_usage, {
                    SUB_APPLICATION => $sub_app,
                    JOBNAME         => $jobname,
                    TASKTYPE        => $tasktype,
                    APPL_TYPE       => $appl_type,
                    CMDLINE         => $cmd,
                };
            }

            # --------------------------------------------------------------
            # CHECK pattern agt_8 (avec lignes matchées)
            # --------------------------------------------------------------
            my @matches_agt8;
            for my $line (split /\n/, $job->toString()) {
                push @matches_agt8, $line if $line =~ /agt_8/;
            }
            if (@matches_agt8) {
                push @agt8_hits, {
                    SUB_APPLICATION => $sub_app,
                    JOBNAME         => $jobname,
                    MATCHES         => [ @matches_agt8 ],
                };
            }

            # --------------------------------------------------------------
            # CHECK pattern agt_9.0.0 (avec lignes matchées)
            # --------------------------------------------------------------
            my @matches_agt9;
            for my $line (split /\n/, $job->toString()) {
                push @matches_agt9, $line if $line =~ /agt_9\.0\.0/;
            }
            if (@matches_agt9) {
                push @agt9_hits, {
                    SUB_APPLICATION => $sub_app,
                    JOBNAME         => $jobname,
                    MATCHES         => [ @matches_agt9 ],
                };
            }
        }
    }

    out($LOG, "\n[2] Composantes applicatives\n");

    out($LOG, "  - FOLDER_ORDER_METHOD : $folder_order_method\n");

    out($LOG, "  - Calendriers (.index.toc) :\n");
    out($LOG, @cals ? join("", map { "      * $_\n" } @cals) : "      (aucun)\n");

    out($LOG, "  - Libmemsyms (.index.toc) :\n");
    out($LOG, @libs ? join("", map { "      * $_\n" } @libs) : "      (aucun)\n");

    out($LOG, "  - Ressources quantitatives (.index.toc /res/quantitative.idx) :\n");
    out($LOG, @quant ? join("", map { "      * $_\n" } @quant) : "      (aucune)\n");

    out($LOG, "  - Ressources quantitatives (schedtable.xml) :\n");
    my @quant_xml = sort grep { defined $_ && $_ ne '' } keys %quantitative_xml;
    out($LOG, @quant_xml ? join("", map { "      * $_\n" } @quant_xml) : "      (aucune)\n");

    out($LOG, "  - NodeID (NODEIDS/NODEGROUP) :\n");
    out($LOG, @all_nid ? join("", map { "      * $_\n" } @all_nid) : "      (aucun)\n");

    out($LOG, "  - Hostgroups (NODEGROUP) :\n");
    out($LOG, @hostgroups ? join("", map { "      * $_\n" } @hostgroups) : "      (aucun)\n");

    out($LOG, "  - SHOUT DEST (schedtable.xml) :\n");
    my @shout_list = sort grep { defined $_ && $_ ne '' } keys %shout_dest;
    out($LOG, @shout_list ? join("", map { "      * $_\n" } @shout_list) : "      (aucun)\n");

    out($LOG, "  - RUN_AS (schedtable.xml) :\n");
    my @run_as_list = sort grep { defined $_ && $_ ne '' } keys %run_as;
    out($LOG, @run_as_list ? join("", map { "      * $_\n" } @run_as_list) : "      (aucun)\n");

    out($LOG, "  - TASK_TYPES :\n");
    if (%tasktypes || %appl_types) {
            for my $t (sort keys %tasktypes) {
                    out($LOG, "      * TASKTYPE : $t\n");
            }
            for my $a (sort keys %appl_types) {
                    out($LOG, "      * APPL_TYPE : $a\n");
            }
    } else {
            out($LOG, " (aucun)\n");
    }

    out($LOG, "  - ODATE=\"STAT\" (schedtable.xml) :\n");
    if (@odate_stat_hits) {
        out($LOG, "      JOBNAME,XML_LINE\n");
        my %seen;
        for my $r (@odate_stat_hits) {
            my ($jn, $line) = @$r;
            my $key = "$jn|$line";
            next if $seen{$key}++;
            out($LOG, "      $jn,$line\n");
        }
    } else {
        out($LOG, "      (aucune)\n");
    }

    out($LOG, "  - JOBS_USER_CTM (RUN_AS = ctmag900/ctmag901) :\n");
    if (@jobs_user_ctm) {
        out($LOG, "      SUB_APPLICATION,JOBNAME,TASKTYPE,APPL_TYPE,CMDLINE\n");
        my %seen;
        for my $j (@jobs_user_ctm) {
            my $line = join(',', map { $j->{$_} // '' }
                qw(SUB_APPLICATION JOBNAME TASKTYPE APPL_TYPE CMDLINE));
            next if $seen{$line}++;
            out($LOG, "      $line\n");
        }
    } else {
        out($LOG, "      (aucun)\n");
    }

    out($LOG, "  - CHECK_SRV_USAGE (NODEID vide/SRV_PRIMAIRE/SRV_BACKUP, TASKTYPE != Dummy) :\n");
    if (@check_srv_usage) {
        out($LOG, "      SUB_APPLICATION,JOBNAME,TASKTYPE,APPL_TYPE,CMDLINE\n");
        my %seen;
        for my $j (@check_srv_usage) {
            my $line = join(',', map { $j->{$_} // '' }
                qw(SUB_APPLICATION JOBNAME TASKTYPE APPL_TYPE CMDLINE));
            next if $seen{$line}++;
            out($LOG, "      $line\n");
        }
    } else {
        out($LOG, "      (aucun)\n");
    }

    # --------------------------------------------------------------
    # CHECK pattern agt_8
    # --------------------------------------------------------------
    out($LOG, "  - CHECK pattern agt_8 :\n");
    if (@agt8_hits) {
        out($LOG, "      SUB_APPLICATION,JOBNAME,MATCH_LINES\n");
        for my $j (@agt8_hits) {
            out($LOG, "      $j->{SUB_APPLICATION},$j->{JOBNAME}\n");
            for my $m (@{ $j->{MATCHES} }) {
                out($LOG, "          > $m\n");
            }
        }
    } else {
        out($LOG, "      (aucun)\n");
    }

    # --------------------------------------------------------------
    # CHECK pattern agt_9.0.0
    # --------------------------------------------------------------
    out($LOG, "  - CHECK pattern agt_9.0.0 :\n");
    if (@agt9_hits) {
        out($LOG, "      SUB_APPLICATION,JOBNAME,MATCH_LINES\n");
        for my $j (@agt9_hits) {
            out($LOG, "      $j->{SUB_APPLICATION},$j->{JOBNAME}\n");
            for my $m (@{ $j->{MATCHES} }) {
                out($LOG, "          > $m\n");
            }
        }
    } else {
        out($LOG, "      (aucun)\n");
    }
    my @conditions = parse_conditions_from_schedtable("$root/schedtable.xml");

    out($LOG, "\n[3] Dépendances en PRODUCTION\n");

    my @prod_archives = grep { archive_matches_dc($_) } glob("$POOL_PROD_DIR/*.tar*");

    out($LOG, "\n  [3.a] Dépendances des conditions\n");
    if (!@conditions) {
        out($LOG, "    (aucune condition à analyser)\n");
    } else {
        my %deps;
        for my $pa (@prod_archives) {
            my $root_pa = get_root_for_pool_archive($pa, 'pool_prod');
            next if get_archive_identity($root_pa) eq $current_id;

            my @matched = find_condition_matches("$root_pa/schedtable.xml", \@conditions);
            $deps{$pa} = \@matched if @matched;
        }
        if (%deps) {
            for my $pa (sort keys %deps) {
                out($LOG, "      * $pa\n");
                out($LOG, join("", map { "          - $_\n" } @{ $deps{$pa} }));
            }
        } else {
            out($LOG, "    Aucune dépendance trouvée.\n");
        }
    }

    out($LOG, "\n  [3.b] Dépendances des Hostgroups / NodeID\n");
    my @keys = (@hostgroups, @all_nid);
    if (!@keys) {
        out($LOG, "    (aucun hostgroup/nodeid à analyser)\n");
    } else {
        my %deps;
        for my $pa (@prod_archives) {
            my $root_pa = get_root_for_pool_archive($pa, 'pool_prod');
            next if get_archive_identity($root_pa) eq $current_id;

            my @matched = find_matches_in_two_files(
                "$root_pa/nod/NODEIDS.dat",
                "$root_pa/nod/NODEGROUP.dat",
                \@keys
            );
            $deps{$pa} = \@matched if @matched;
        }
        if (%deps) {
            for my $pa (sort keys %deps) {
                out($LOG, "      * $pa\n");
                out($LOG, join("", map { "          - $_\n" } @{ $deps{$pa} }));
            }
        } else {
            out($LOG, "    Aucune dépendance trouvée.\n");
        }
    }

    out($LOG, "\n  [3.c] Dépendances des ressources quantitatives\n");
    if (!@quant) {
        out($LOG, "    (aucune quantitative à analyser)\n");
    } else {
        my %deps;
        for my $pa (@prod_archives) {
            my $root_pa = get_root_for_pool_archive($pa, 'pool_prod');
            next if get_archive_identity($root_pa) eq $current_id;

            my @matched = find_quantitative_matches("$root_pa/schedtable.xml", \@quant);
            $deps{$pa} = \@matched if @matched;
        }
        if (%deps) {
            for my $pa (sort keys %deps) {
                out($LOG, "      * $pa\n");
                out($LOG, join("", map { "          - $_\n" } @{ $deps{$pa} }));
            }
        } else {
            out($LOG, "    Aucune dépendance trouvée.\n");
        }
    }

    out($LOG, "\n[4] Dépendances en HORS PRODUCTION\n");

    my @hp_archives = grep { archive_matches_dc($_) } glob("$POOL_HPROD_DIR/*.tar*");

    if (!@keys) {
        out($LOG, "    (aucun hostgroup/nodeid à analyser)\n");
    } else {
        my %deps;
        for my $pa (@hp_archives) {
            my $root_pa = get_root_for_pool_archive($pa, 'pool_horsprod');
            next if get_archive_identity($root_pa) eq $current_id;

            my @matched = find_matches_in_two_files(
                "$root_pa/nod/NODEIDS.dat",
                "$root_pa/nod/NODEGROUP.dat",
                \@keys
            );
            $deps{$pa} = \@matched if @matched;
        }

        if (%deps) {
            for my $pa (sort keys %deps) {
                out($LOG, "      * $pa\n");
                out($LOG, join("", map { "          - $_\n" } @{ $deps{$pa} }));
            }
        } else {
            out($LOG, "    Aucune dépendance trouvée.\n");
        }
    }

    out($LOG, "\n--- Fin d'analyse pour $archive ---\n");
    out($LOG, "Log généré : $logfile\n");

    close $LOG;
}
# ----------------------------------------------------------------------
# Programme principal
# ----------------------------------------------------------------------
chdir $ANALYSE_DIR or die "Impossible d'aller dans $ANALYSE_DIR: $!\n";
make_path($TMP_DIR) unless -d $TMP_DIR;

purge_tmp();

my @archives = glob("*.tar*");
die "Aucune archive trouvée dans $ANALYSE_DIR\n" unless @archives;

foreach my $a (@archives) {
    analyse_archive("$ANALYSE_DIR/$a");
}

print "\nAnalyse terminée.\n";
exit 0;

