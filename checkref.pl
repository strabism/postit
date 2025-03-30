use strict;
use warnings;
use XML::LibXML;
use POSIX qw(strftime);

# Vérification de l'argument
my $xml_file = shift or die "Usage: $0 <schedtable.xml>\n";

# Charger le fichier XML
my $parser = XML::LibXML->new();
my $doc = $parser->load_xml(location => $xml_file);

# Récupération du folder_name principal
my ($folder_node) = $doc->findnodes('//FOLDER');
my $folder_name = $folder_node ? $folder_node->findvalue('@FOLDER_NAME') : 'Inconnu';

# Stockage des folder_name pour chaque JOB
my %folder_names;
foreach my $folder ($doc->findnodes('//FOLDER')) {
    my $folder_name = $folder->findvalue('@FOLDER_NAME');
    foreach my $job ($folder->findnodes('.//JOB')) {
        $folder_names{$job->findvalue('@JOBNAME')} = $folder_name;
    }
}

# Validation et comptage
my (%results, %stats);
my $total_checks = 0;
my $total_conform = 0;

foreach my $job ($doc->findnodes('//JOB')) {
    my $jobname = $job->findvalue('@JOBNAME');
    my $application = $job->findvalue('@APPLICATION');
    my $sub_application = $job->findvalue('@SUB_APPLICATION');
    my $nodeid = $job->findvalue('@NODEID');
    my $folder_name = $folder_names{$jobname} // '';
    
    # Initialiser stockage par sub_application
    $results{$sub_application} //= [];
    $stats{$sub_application}{total} //= 0;
    $stats{$sub_application}{conform} //= 0;

    # Vérification APPLICATION == FOLDER_NAME
    if ($application) {
        my $is_conform = ($folder_name && $application eq $folder_name && length($application) == 9);
        push @{$results{$sub_application}}, [$jobname, 'APPLICATION', $application, 'APPLICATION doit être égal à FOLDER_NAME et 9 caractères', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    # Vérification NODEID (uniquement s'il existe)
    if ($nodeid) {
        my $is_conform = (length($nodeid) == 10 && uc($nodeid) eq $nodeid);
        push @{$results{$sub_application}}, [$jobname, 'NODEID', $nodeid, 'NODEID doit être en majuscule et 10 caractères', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    # Vérification INCOND
    foreach my $incond ($job->findnodes('./INCOND')) {
        my $cond_name = $incond->findvalue('@NAME');
        next unless $cond_name;
        my $is_conform = ($application && substr($cond_name, 0, 9) eq $application);
        push @{$results{$sub_application}}, [$jobname, 'INCOND', $cond_name, 'Nom INCOND doit commencer par les 9 premiers caractères de APPLICATION', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    # Vérification OUTCOND
    foreach my $outcond ($job->findnodes('./OUTCOND')) {
        my $cond_name = $outcond->findvalue('@NAME');
        next unless $cond_name;
        my $is_conform = ($application && $jobname && $cond_name =~ /^${application}${jobname}-(OK|KO|ER|C[0-9]|LO|ENDED)$/);
        push @{$results{$sub_application}}, [$jobname, 'OUTCOND', $cond_name, 'Nom OUTCOND doit commencer par APPLICATION + JOBNAME + suffixe valide', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    $total_checks += $stats{$sub_application}{total};
    $total_conform += $stats{$sub_application}{conform};
}

# Génération HTML
my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
print "<html><body>";
print "<h1>Homologation chaine Control-M : $folder_name</h1>";
print "<p>Généré le : $timestamp</p>";

foreach my $sub_app (keys %results) {
    print "<h2>Vérifications pour SUB_APPLICATION: $sub_app</h2>";
    print "<table border='1'><tr><th>JOBNAME</th><th>Champ</th><th>Valeur</th><th>Règle</th><th>Conformité</th></tr>";
    
    foreach my $row (@{$results{$sub_app}}) {
        my ($jobname, $field, $value, $rule, $status) = @$row;
        my $color = $status ? 'green' : 'red';
        print "<tr><td>$jobname</td><td>$field</td><td>$value</td><td>$rule</td><td style='color:$color;'>" . ($status ? 'Conforme' : 'Non conforme') . "</td></tr>";
    }
    print "</table>";
}

my $total_percent = $total_checks ? sprintf("%.2f", ($total_conform / $total_checks) * 100) : 0;
print "<h2>Résumé Global</h2><p>Total de conformités: $total_conform / $total_checks ($total_percent%)</p>";

# Écriture dans le fichier de log
open my $log_fh, '>>', 'homol.log' or die "Impossible d'ouvrir homol.log: $!";
print $log_fh "$timestamp, $folder_name, $total_percent%\n";
close $log_fh;

print "</body></html>";
