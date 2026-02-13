#!/usr/bin/perl
use strict;
use warnings;
use XML::LibXML;

###############################################
# TABLE DE CORRESPONDANCE SERVEUR → ALIAS
# Ajoute ici autant de correspondances que tu veux
###############################################
my %server_map = (
    'SERVERCTM1' => 'serveur',
    'SERVERCTM2' => 'serveur',
    'SERVERCTM3' => 'serveur',
);

###############################################
# Répertoire contenant les fichiers .data
###############################################
my $dir = ".";

opendir(my $dh, $dir) or die "Impossible d'ouvrir $dir: $!";
my @files = grep { /\.data$/ && -f "$dir/$_" } readdir($dh);
closedir($dh);

###############################################
# En-tête CSV
###############################################
print "server;application;sub_application;jobname;cmdline\n";

foreach my $file (@files) {
    my $path = "$dir/$file";

    my $dom;
    eval {
        $dom = XML::LibXML->load_xml(location => $path);
    };
    if ($@) {
        warn "Erreur XML dans $file : $@\n";
        next;
    }

    ###############################################
    # Récupération du DATACENTER dans la balise FOLDER
    ###############################################
    my ($folder) = $dom->findnodes('//FOLDER');
    next unless $folder;

    my $datacenter = $folder->getAttribute('DATACENTER') // '';

    # Conversion via la table de correspondance
    my $server = exists $server_map{$datacenter}
               ? $server_map{$datacenter}
               : $datacenter;   # si pas trouvé, on garde la valeur brute

    ###############################################
    # Parcours des JOB
    ###############################################
    foreach my $job ($dom->findnodes('//JOB')) {

        my $jobname     = $job->getAttribute('JOBNAME')        // '';
        my $application = $job->getAttribute('APPLICATION')    // '';
        my $subapp      = $job->getAttribute('SUB_APPLICATION')// '';
        my $cmdline     = $job->getAttribute('CMDLINE')        // '';

        next unless $cmdline =~ /scripttoto\.sh/;

        print "$server;$application;$subapp;$jobname;$cmdline\n";
    }
}
