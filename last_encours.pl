use strict;
use warnings;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use File::Slurp;
use List::MoreUtils qw(uniq);
use XML::LibXML;

# Déclaration de la variable $POOL_DIR
my $POOL_DIR = "pool";  # Répertoire contenant les archives

# Fonction de log
sub log_message {
    my ($level, $message) = @_;
    my $timestamp = localtime;
    print "$timestamp [$level] $message\n";
}

# Fonction pour extraire une valeur spécifique d'un fichier .index.toc
sub extract_value_from_file {
    my ($file_path, $key) = @_;
    my $value = "";

    if (-e $file_path) {
        my @lines = read_file($file_path);
        foreach my $line (@lines) {
            if ($line =~ /^$key\s*=\s*(.*)/i) {
                $value = $1;
                #log_message("INFO", "$key trouvé dans $file_path: $value");
                last;
            }
        }
    }
    return $value;
}

# Fonction pour récupérer toutes les valeurs APPL_TYPE dans le fichier XML
sub extract_appl_type {
    my ($xml_file) = @_;
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file($xml_file);
    my @appl_types = map { $_->textContent } $doc->findnodes('//@APPL_TYPE');
    #log_message("INFO", "APPL_TYPE extrait: " . join(":", uniq(@appl_types)));
    return join(":", uniq(@appl_types));
}

# Fonction pour extraire LIST_COND 
sub extract_list_cond {
    my ($xml_file) = @_;
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file($xml_file);
    my @list_cond = map { $_->getAttribute('NAME') } $doc->findnodes('//INCOND | //OUTCOND');
    #log_message("INFO", "LIST_COND extrait: " . join(":", uniq(@list_cond)));
    return join(":", uniq(@list_cond));
}

# Fonction pour récupérer la valeur LAST_UPLOAD
sub extract_last_upload {
    my ($xml_file) = @_;
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file($xml_file);
    my ($last_upload) = $doc->findnodes('//@LAST_UPLOAD');
    #log_message("INFO", "LAST_UPLOAD extrait: " . ($last_upload ? $last_upload->value : "not_set"));
    return $last_upload ? $last_upload->value : "not_set";
}

# Fonction pour récupérer la valeur USERDAILY_CHECK
sub extract_userdaily_check {
    my ($xml_file) = @_;
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file($xml_file);
    my ($userdaily_check) = $doc->findnodes('//@FOLDER_ORDER_METHOD');
    #log_message("INFO", "USERDAILY_CHECK extrait: " . ($userdaily_check ? $userdaily_check->value : "MANUAL"));
    return $userdaily_check ? $userdaily_check->value : "MANUAL";
}

# Fonction pour gérer les dépendances générales
sub check_dependencies {
    my ($key, $value, $index_file, $ignore_case, $exclude_value) = @_;
    return if !$value;  # Si aucune valeur donnée, on sort directement

    # Séparer les valeurs par ":" et créer une liste
    my @list_values = split /:/, $value;

    # Exclure la valeur spécifique de la liste, si elle est présente
    if (defined $exclude_value) {
        @list_values = grep { $_ ne $exclude_value } @list_values;
    }

    # Si après exclusion, la liste est vide, on sort
    return if !@list_values;

    my @dependency_results;

    opendir(my $dh_pool, $POOL_DIR) or die "Impossible d'ouvrir $POOL_DIR : $!";
    my @dirs = grep { -d File::Spec->catfile($POOL_DIR, $_) } readdir($dh_pool);
    closedir($dh_pool);

    foreach my $val_check (@list_values) {
        my @exp_tables_for_value;
        foreach my $dir (@dirs) {
            my $sub_index_file = File::Spec->catfile($POOL_DIR, $dir, ".index.toc");
            next if $sub_index_file eq $index_file;

            if (-e $sub_index_file) {
                #log_message("INFO", "Vérification dans $sub_index_file");
                my @lines = read_file($sub_index_file);
                foreach my $line (@lines) {
                    if (($ignore_case && $line =~ /$key.*$val_check/i) || (!$ignore_case && $line =~ /$key.*$val_check/)) {
                        #log_message("INFO", "Correspondance trouvée dans $sub_index_file pour $val_check");
                        my $exp_table = extract_value_from_file($sub_index_file, "EXP_TABLE");
                        push @exp_tables_for_value, $exp_table if $exp_table;
                    }
                }
            }
        }

        if (@exp_tables_for_value) {
            my $exp_tables_str = join(":", @exp_tables_for_value);
            push @dependency_results, "$val_check=>$exp_tables_str";
        }
    }

    return join(",", @dependency_results);
}

use strict;
use warnings;
use File::Basename;
use File::Spec;
use XML::LibXML;

sub check_condition_in_other_schedtables {
    my ($list_cond, $dc, $schedtable_file) = @_;
    my @condition_dependencies;

    # Récupérer le répertoire courant
    my $schedtable_file_dir = dirname($schedtable_file);

    # Ouvrir le dossier du pool
    opendir(my $dh_pool, $POOL_DIR) or die "Impossible d'ouvrir $POOL_DIR : $!";
    my @dirs = grep { -d File::Spec->catfile($POOL_DIR, $_) && $_ !~ /^\.\.?$/ } readdir($dh_pool);
    closedir($dh_pool);

    # Filtrer les répertoires qui contiennent le nom du DataCenter ($dc)
    @dirs = grep { $_ =~ /\Q$dc\E/ } @dirs;

    # Exclure le répertoire en cours
    @dirs = grep { $_ ne basename($schedtable_file_dir) } @dirs;

    # Convertir la liste des conditions en tableau pour recherche rapide
    my %conditions = map { $_ => 1 } split(/:/, $list_cond);

    foreach my $dir (@dirs) {
        my $schedtable_path = File::Spec->catfile($POOL_DIR, $dir, "schedtable.xml");

        next unless -e $schedtable_path;  # Vérifier si le fichier existe

        # Par défaut, si on ne trouve pas FOLDER_NAME
        my $folder_name = "UNKNOWN";

        # Charger et parser le fichier XML
        my $parser = XML::LibXML->new();
        my $doc;
        eval { $doc = $parser->parse_file($schedtable_path); };
        if ($@) {
            log_message("ERROR", "Erreur XML dans $schedtable_path : $@");
            next;
        }

        # Trouver le FOLDER_NAME dans <FOLDER> ou <SMART_FOLDER>
        my ($folder_node) = $doc->findnodes('//FOLDER[@FOLDER_NAME] | //SMART_FOLDER[@FOLDER_NAME]');
        if ($folder_node) {
            $folder_name = $folder_node->getAttribute('FOLDER_NAME');
        }

        # Vérifier si une condition de list_cond est présente dans INCOND/OUTCOND
        foreach my $cond ($doc->findnodes('//INCOND/@NAME | //OUTCOND/@NAME')) {
            my $cond_name = $cond->value;
            if (exists $conditions{$cond_name}) {
                push @condition_dependencies, "$cond_name=>$folder_name";
            }
        }
    }

    return join(",", @condition_dependencies);
}

sub nb_elements_exp {
    my ($input_string) = @_;  # Variable d'entrée

    # Si la chaîne n'est pas vide, on la sépare par ":" et on retourne le nombre d'éléments
    my $count = 0;
    if ($input_string) {
        my @elements = split /:/, $input_string;
        $count = scalar @elements;
    }

    return $count;
}

# Lister les fichiers .tar
opendir(my $dh, $POOL_DIR) or die "Impossible d'ouvrir $POOL_DIR : $!";
my @archives = grep { /.tar$/ && -f File::Spec->catfile($POOL_DIR, $_) } readdir($dh);
closedir($dh);

if (!@archives) {
    log_message("INFO", "Aucune archive trouvée dans $POOL_DIR.");
    exit 0;
}

# Pour chaque archive
foreach my $tar_file (@archives) {
    my $full_path = File::Spec->catfile($POOL_DIR, $tar_file);
    my $extract_dir = File::Spec->catfile($POOL_DIR, basename($tar_file, ".tar"));

    if (-d $extract_dir) {
        #log_message("INFO", "[EXTRACTION] L'archive $tar_file est déjà extraite.");
    } else {
        #log_message("INFO", "Extraction de $tar_file dans $extract_dir...");
        make_path($extract_dir) unless -d $extract_dir;
        system("tar -xf $full_path -C $POOL_DIR") == 0 or die "Erreur lors de l'extraction de $tar_file : $!";
    }

    my $index_file = File::Spec->catfile($extract_dir, ".index.toc");
    #log_message("INFO", "Lecture de $index_file...");

    my %exp_vars;
    foreach my $key ("EXP_CAL", "EXP_NID", "EXP_NOD", "EXP_LIB", "EXP_TABLE", "EXP_DC") {
        $exp_vars{$key} = extract_value_from_file($index_file, $key);
    }
	my $exp_table_live = extract_value_from_file($index_file, "EXP_TABLE");
	log_message("@@@@@@@@@@", "######################################");
	log_message("INFO", "EXP_TABLE: $exp_table_live");
	my $exp_nod_live = extract_value_from_file($index_file, "EXP_NOD");
	my $exp_table_nod_count = nb_elements_exp($exp_nod_live);
	log_message("INFO", "NB_EXP_NOD: $exp_table_nod_count");

    # Extraction d'APPL_TYPE, NB_COND, LAST_UPLOAD et USERDAILY_CHECK
    my $schedtable_file = File::Spec->catfile($extract_dir, "schedtable.xml");
    my $appl_type = extract_appl_type($schedtable_file);
    my $last_upload = extract_last_upload($schedtable_file);
    my $userdaily_check = extract_userdaily_check($schedtable_file);

    # Récupérer le nombre de conditions
    my $list_cond = extract_list_cond($schedtable_file);
    my $nb_cond = ($list_cond) ? scalar(split /:/, $list_cond) : 0;

    #log_message("INFO", "APPL_TYPE: $appl_type");
    #log_message("INFO", "NB_COND: $nb_cond");
    #log_message("INFO", "LIST_COND: $list_cond");
    #log_message("INFO", "LAST_UPLOAD: $last_upload");
    #log_message("INFO", "USERDAILY_CHECK: $userdaily_check");

    # Vérification des dépendances
    my $ad_cal_csv = check_dependencies("EXP_CAL", $exp_vars{EXP_CAL}, $index_file, 1, "STANDARD");
    my $ad_nid_csv = check_dependencies("EXP_NID", $exp_vars{EXP_NID}, $index_file, 1);
    my $ad_nod_csv = check_dependencies("EXP_NOD", $exp_vars{EXP_NOD}, $index_file, 1, "SRV_PRIMAIRE");
    my $ad_lib_csv = check_dependencies("EXP_LIB", $exp_vars{EXP_LIB}, $index_file, 1);


    # Si aucune dépendance n'a été trouvée, on les initialise à une chaîne vide
    $ad_cal_csv = "" unless defined $ad_cal_csv;
    $ad_nid_csv = "" unless defined $ad_nid_csv;
    $ad_nod_csv = "" unless defined $ad_nod_csv;
    $ad_lib_csv = "" unless defined $ad_lib_csv;

    log_message("INFO", "Dépendances CAL=>EXP_TABLE: $ad_cal_csv");
    log_message("INFO", "Dépendances NID=>EXP_TABLE: $ad_nid_csv");
    log_message("INFO", "Dépendances NOD=>EXP_TABLE: $ad_nod_csv");
    log_message("INFO", "Dépendances LIB=>EXP_TABLE: $ad_lib_csv");
	log_message("INFO", "$exp_vars{EXP_DC}");
	
	# Vérification des dépendances
	my $condition_dependencies = check_condition_in_other_schedtables($list_cond, $exp_vars{"EXP_DC"}, $schedtable_file);
	log_message("INFO", "Dépendance Conditions : $condition_dependencies");
    open my $csv, '>>', "Final.csv" or die "Impossible d'ouvrir Final.csv : $!";
    print $csv "$appl_type;$nb_cond;$list_cond;$last_upload;$userdaily_check;$ad_cal_csv;$ad_nid_csv;$ad_nod_csv;$ad_lib_csv\n";
    close $csv;
}
#echo "$EXP_TABLE;$FOLDER_TYPE;$EXP_DC;$LAST_UPLOAD;$EXP_JOBS;$NB_EXP_NOD;$NB_EXP_NID;$NB_EXP_LIB;$NB_EXP_RES;$NB_COND;$NB_EXP_CAL;$APPL_TYPE;$USERDAILY;$EXP_SHOUT;$RUN_AS;$AD_CAL_CSV;$AD_LIB_CSV;$AD_NOD_CSV;$AD_NOD_NID;$AD_RES_CSV;$AD_USERDAILY_CSV;$AD_COND_CSV" >> Final.csv
#a inclure : FOLDER_TYPE
#			 SHOUT
#			 RUN AS

