use strict;
use warnings;
use POSIX qw(strftime);
use XML::Simple;
use File::Basename;
use File::Find;
use Text::CSV;

sub log {
    my ($level, $message) = @_;
    print strftime('%Y-%m-%d %H:%M:%S', localtime) . " [$level] $message\n";
}

# Vidage du fichier CSV et ajout du header
my $csv_file = 'Final.csv';
open my $fh, '>', $csv_file or die "Cannot open $csv_file: $!";
print $fh "NOM_REF;FOLDER_TYPE;DATACENTER;LAST_UPLOAD;NB_JOBS;NB_HOSTGROUPS;NB_HOSTID;NB_LIBM;NB_QR;NB_COND;NB_CALENDAR;JOB_TYPE;USERDAILY;SHOUT;RUN_AS;AD_CALENDAR;AD_LIBM;AD_HOSTGROUPS;AD_HOSTID;AD_QR;AD_USERDAILY;AD_COND\n";
close $fh;

# Décompression des fichiers tar.gz
my $dir = 'pool';
opendir(my $dh, $dir) or die "Cannot open directory $dir: $!";
my @files = grep { /\.tar\.gz$/ } readdir($dh);
closedir($dh);

foreach my $file (@files) {
    my $tar_file = "$dir/$file";
    my $extract_dir = "$dir/" . basename($file, '.tar.gz');
    
    if (! -d $extract_dir) {
        log("INFO", "Extraction de $tar_file dans $extract_dir...");
        my $tar = Archive::Tar->new($tar_file);
        if ($tar->extract($extract_dir)) {
            log("INFO", "Extraction $tar_file OK");
        } else {
            log("ERREUR", "Échec de l'extraction de $tar_file ...Exit");
            exit 1;
        }
    } else {
        log("INFO", "[EXTRACTION] L'archive $tar_file est déjà extraite.");
    }
}

# Boucle sur les répertoires et récupération des informations
opendir($dh, $dir) or die "Cannot open directory $dir: $!";
my @reps = grep { -d "$dir/$_" && !/^\./ } readdir($dh);
closedir($dh);

open $fh, '>>', $csv_file or die "Cannot open $csv_file: $!";

foreach my $rep (@reps) {
    my $index_file = "$dir/$rep/.index.toc";
    my $schedtable_file = "$dir/$rep/schedtable.xml";

    # Lecture des informations du fichier .index.toc
    my %index_data;
    open my $index_fh, '<', $index_file or die "Cannot open $index_file: $!";
    while (<$index_fh>) {
        chomp;
        my @fields = split(':');
        foreach my $field (@fields) {
            if ($field =~ /^(EXP_\w+)=(.+)$/) {
                $index_data{$1} = $2;
            }
        }
    }
    close $index_fh;

    # Parsing du fichier schedtable.xml
    my $xml = XML::Simple->new();
    my $data = $xml->XMLin($schedtable_file);

    # Extraction des informations spécifiques
    my $appl_type = join(':', keys %{{ map { $_ => 1 } map { $_ =~ /APPL_TYPE="([^"]+)"/ ? $1 : () } @{$data->{Job}} }});
    my $nb_cond = grep { $_ =~ /INCOND|OUTCOND/ } @{$data->{Job}};
    my $list_cond = join("\n", map { $_ =~ /NAME="([^"]+)"/ ? $1 : () } @{$data->{Job}});
    my $last_upload = $data->{LAST_UPLOAD};
    my $run_as = join(':', keys %{{ map { $_ => 1 } map { $_ =~ /RUN_AS="([^"]+)"/ ? $1 : () } @{$data->{Job}} }});
    my $userdaily_check = $data->{FOLDER_ORDER_METHOD} // 'MANUAL';
    my $exp_cr = grep { $_ =~ /CONTROL NAME="([^"]+)"/ } @{$data->{Job}};
    my $folder_type = $data->{SMART_FOLDER} ? 'SMARTFOLDER' : 'FOLDER';

 # Adhérences Calendrier
    my $exp_cal = $index_data{EXP_CAL} // '';
    my @list_exp_cal = split(':', $exp_cal);
    my $nb_exp_cal = scalar @list_exp_cal;

    my $ad_cal_csv = '';
    if ($nb_exp_cal > 0) {
        foreach my $cal_check (@list_exp_cal) {
            next if $cal_check eq 'STANDARD';

            my @ad_exp_table_cal_array;
            my $ad_exp_cal = `grep -lr --exclude="$index_file" "EXP_CAL.*$cal_check" $dir/*${index_data{EXP_DC}}*/.index.toc`;
            chomp $ad_exp_cal;

            if ($ad_exp_cal) {
                my @list_ad_exp_cal = split(' ', $ad_exp_cal);
                foreach my $ad_exp_cal (@list_ad_exp_cal) {
                    open my $ad_fh, '<', $ad_exp_cal or die "Cannot open $ad_exp_cal: $!";
                    while (<$ad_fh>) {
                        if (/EXP_TABLE=(.+)/) {
                            push @ad_exp_table_cal_array, $1;
                        }
                    }
                    close $ad_fh;
                }
                my $ad_cal_tr_csv = join(':', @ad_exp_table_cal_array);
                $ad_cal_csv .= "$cal_check@$ad_cal_tr_csv:";
            }
        }
        $ad_cal_csv =~ s/:$//;  # Enlever le dernier ':'
    }

    # Adhérences Libmemsyms
    my $exp_lib = $index_data{EXP_LIB} // '';
    my @list_exp_lib = split(':', $exp_lib);
    my $nb_exp_lib = scalar @list_exp_lib;

    my $ad_lib_csv = '';
    if ($nb_exp_lib > 0) {
        foreach my $lib_check (@list_exp_lib) {
            my @ad_exp_table_lib_array;
            my $ad_exp_lib = `grep -lr --exclude="$index_file" "EXP_LIB.*$lib_check" $dir/*${index_data{EXP_DC}}*/.index.toc`;
            chomp $ad_exp_lib;

            if ($ad_exp_lib) {
                my @list_ad_exp_lib = split(' ', $ad_exp_lib);
                foreach my $ad_exp_lib (@list_ad_exp_lib) {
                    open my $ad_fh, '<', $ad_exp_lib or die "Cannot open $ad_exp_lib: $!";
                    while (<$ad_fh>) {
                        if (/EXP_TABLE=(.+)/) {
                            push @ad_exp_table_lib_array, $1;
                        }
                    }
                    close $ad_fh;
                }
                my $ad_lib_tr_csv = join(':', @ad_exp_table_lib_array);
                $ad_lib_csv .= "$lib_check@$ad_lib_tr_csv:";
            }
        }
        $ad_lib_csv =~ s/:$//;  # Enlever le dernier ':'
    }

    # Adhérences NID (nodeid)
    my $exp_nid = $index_data{EXP_NID} // '';
    my @list_exp_nid = split(':', $exp_nid);
    my $nb_exp_nid = scalar @list_exp_nid;

    my $ad_nid_csv = '';
    if ($nb_exp_nid > 0) {
        foreach my $nid_check (@list_exp_nid) {
            my @ad_exp_table_nid_array;
            my $ad_exp_nid = `grep -lr --exclude="$index_file" "EXP_NID.*$nid_check" $dir/*${index_data{EXP_DC}}*/.index.toc`;
            chomp $ad_exp_nid;

            if ($ad_exp_nid) {
                my @list_ad_exp_nid = split(' ', $ad_exp_nid);
                foreach my $ad_exp_nid (@list_ad_exp_nid) {
                    open my $ad_fh, '<', $ad_exp_nid or die "Cannot open $ad_exp_nid: $!";
                    while (<$ad_fh>) {
                        if (/EXP_TABLE=(.+)/) {
                            push @ad_exp_table_nid_array, $1;
                        }
                    }
                    close $ad_fh;
                }
                my $ad_nid_tr_csv = join(':', @ad_exp_table_nid_array);
                $ad_nid_csv .= "$nid_check@$ad_nid_tr_csv:";
            }
        }
        $ad_nid_csv =~ s/:$//;  # Enlever le dernier ':'
    }

    # Adhérences NOD
    my $exp_nod = $index_data{EXP_NOD} // '';
    my @list_exp_nod = split(':', $exp_nod);
    my $nb_exp_nod = scalar @list_exp_nod;

    my $ad_nod_csv = '';
    if ($nb_exp_nod > 0) {
        foreach my $nod_check (@list_exp_nod) {
            next if $nod_check eq 'SRV_PRIMAIRE';

            my @ad_exp_table_nod_array;
            my $ad_exp_nod = `grep -lr --exclude="$index_file" "EXP_NOD.*$nod_check" $dir/*${index_data{EXP_DC}}*/.index.toc`;
            chomp $ad_exp_nod;

            if ($ad_exp_nod) {
                my @list_ad_exp_nod = split(' ', $ad_exp_nod);
                foreach my $ad_exp_nod (@list_ad_exp_nod) {
                    open my $ad_fh, '<', $ad_exp_nod or die "Cannot open $ad_exp_nod: $!";
                    while (<$ad_fh>) {
                        if (/EXP_TABLE=(.+)/) {
                            push @ad_exp_table_nod_array, $1;
                        }
                    }
                    close $ad_fh;
                }
                my $ad_nod_tr_csv = join(':', @ad_exp_table_nod_array);
                $ad_nod_csv .= "$nod_check@$ad_nod_tr_csv:";
            }
        }
        $ad_nod_csv =~ s/:$//;  # Enlever le dernier ':'
    }

# Adhérences QR
    my $exp_res = $index_data{EXP_RES} // '';
    my @list_exp_res = split(':', $exp_res);
    my $nb_exp_res = scalar @list_exp_res;

    my $ad_res_csv = '';
    if ($nb_exp_res > 0) {
        foreach my $res_check (@list_exp_res) {
            my @ad_exp_table_res_array;
            my $ad_exp_res = `grep -lr --exclude="$index_file" "EXP_RES.*$res_check" $dir/*${index_data{EXP_DC}}*/.index.toc`;
            chomp $ad_exp_res;

            if ($ad_exp_res) {
                my @list_ad_exp_res = split(' ', $ad_exp_res);
                foreach my $ad_exp_res (@list_ad_exp_res) {
                    open my $ad_fh, '<', $ad_exp_res or die "Cannot open $ad_exp_res: $!";
                    while (<$ad_fh>) {
                        if (/EXP_TABLE=(.+)/) {
                            push @ad_exp_table_res_array, $1;
                        }
                    }
                    close $ad_fh;
                }
                my $ad_res_tr_csv = join(':', @ad_exp_table_res_array);
                $ad_res_csv .= "$res_check@$ad_res_tr_csv:";
            }
        }
        $ad_res_csv =~ s/:$//;  # Enlever le dernier ':'
    }

    # Adhérences Conditions
    my $ad_cond_csv = '';
    foreach my $cond_check (split("\n", $list_cond)) {
        next if $cond_check eq '';

        my @ad_exp_table_cond_array;
        my $ad_exp_cond = `grep -lr -- "$cond_check" $dir/*${index_data{EXP_DC}}*/schedtable.xml | grep -v "$index_data{EXP_TABLE}"`;
        chomp $ad_exp_cond;

        if ($ad_exp_cond) {
            my @list_ad_exp_cond = split(' ', $ad_exp_cond);
            foreach my $ad_exp_cond (@list_ad_exp_cond) {
                open my $ad_fh, '<', $ad_exp_cond or die "Cannot open $ad_exp_cond: $!";
                while (<$ad_fh>) {
                    if (/FOLDER_NAME="([^"]+)"/) {
                        push @ad_exp_table_cond_array, $1;
                    }
                }
                close $ad_fh;
            }
            my $ad_cond_tr_csv = join(':', @ad_exp_table_cond_array);
            $ad_cond_csv .= "$cond_check@$ad_cond_tr_csv:";
        }
    }
    $ad_cond_csv =~ s/:$//;  # Enlever le dernier ':'

# Écriture dans le fichier CSV
    print $fh join(';', $index_data{EXP_TABLE}, $folder_type, $index_data{EXP_DC}, $last_upload, $index_data{EXP_JOBS}, scalar @list_exp_nod, scalar @list_exp_nid, scalar @list_exp_lib, scalar @list_exp_res, $nb_cond, scalar @list_exp_cal, $appl_type, $userdaily_check, $index_data{EXP_SHOUT}, $run_as, $ad_cal_csv, $ad_lib_csv, $ad_nod_csv, $ad_nid_csv, $ad_res_csv, $userdaily_check, $ad_cond_csv) . "\n";
}

close $fh;
