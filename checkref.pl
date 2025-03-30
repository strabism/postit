#PLA
#normes CTM
#anonymisee
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
my $folder_order_method = $folder_node ? $folder_node->findvalue('@FOLDER_ORDER_METHOD') : '';

# Vérification de FOLDER_ORDER_METHOD
my $folder_order_valid = ($folder_order_method eq 'SYSTEM' || $folder_order_method =~ /^CTM\d{4}$/);

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
    my $cyclic = $job->findvalue('@CYCLIC');
    my $maxwait = $job->findvalue('@MAXWAIT');
    my $folder_name = $folder_names{$jobname} // '';
    
    # Initialiser stockage par sub_application
    $results{$sub_application} //= [];
    $stats{$sub_application}{total} = 0;
    $stats{$sub_application}{conform} = 0;
    
    # Vérification APPLICATION == FOLDER_NAME
    if (defined $application) {
        my $is_conform = (defined $folder_name && $application eq $folder_name && length($application) == 9);
        push @{$results{$sub_application}}, [$jobname, 'APPLICATION', $application, 'APPLICATION doit être égal à FOLDER_NAME et 9 caractères', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    # Vérification SUB_APPLICATION
    if (defined $sub_application) {
        my $is_conform = (length($sub_application) == 5 && $sub_application =~ /^[NWFx]/i);
        push @{$results{$sub_application}}, [$jobname, 'SUB_APPLICATION', $sub_application, 'SUB_APPLICATION doit être de 5 caractères et commencer par N, W, F ou X', $is_conform];
    }
    
    # Vérification NODEID
    if (defined $nodeid && $nodeid ne '') {
        my $is_conform = (length($nodeid) == 10 && uc($nodeid) eq $nodeid && substr($nodeid, 0, 7) eq substr($application, 0, 7));
        push @{$results{$sub_application}}, [$jobname, 'NODEID', $nodeid, 'NODEID doit être en majuscule, 10 caractères et 7 premiers identiques à APPLICATION', $is_conform];
    }
    
    # Vérification MAXWAIT en fonction de CYCLIC
    if ($cyclic eq '1') {
        push @{$results{$sub_application}}, [$jobname, 'MAXWAIT', $maxwait, 'Si CYCLIC=1, MAXWAIT doit être 0', ($maxwait eq '0')];
    } elsif ($cyclic eq '0') {
        push @{$results{$sub_application}}, [$jobname, 'MAXWAIT', $maxwait, 'Si CYCLIC=0, MAXWAIT doit être 99', ($maxwait eq '99')];
    }
    
    # Vérification des INCOND et OUTCOND
    foreach my $incond ($job->findnodes('./INCOND')) {
        my $cond_name = $incond->findvalue('@NAME');
        my $is_conform = (length($cond_name) >= 17 && $cond_name !~ /^GC/ && $cond_name =~ /-(OK|KO|ER|C[0-9]|LO|ENDED)$/);
        push @{$results{$sub_application}}, [$jobname, 'INCOND', $cond_name, 'Nom INCOND doit avoir au moins 17 caractères, suffixe valide, et ne pas commencer par GC', $is_conform];
    }
    
    foreach my $outcond ($job->findnodes('./OUTCOND')) {
        my $cond_name = $outcond->findvalue('@NAME');
        my $is_conform = ($cond_name =~ /^${application}${jobname}-(OK|KO|ER|C[0-9]|LO|ENDED)$/ && $cond_name !~ /^GC/);
        push @{$results{$sub_application}}, [$jobname, 'OUTCOND', $cond_name, 'Nom OUTCOND doit suivre le format APPLICATION+JOBNAME+suffixe et ne pas commencer par GC', $is_conform];
    }

    # Vérification de la variable %%LIBMEMSYM
    foreach my $variable ($job->findnodes('./VARIABLE')) {
        my $var_name = $variable->findvalue('@NAME');
        my $var_value = $variable->findvalue('@VALUE');
        
        if ($var_name eq '%%LIBMEMSYM' && $var_value =~ /\/([^\/]+)$/) {
            my $last_part = $1;
            my $is_conform = ($last_part eq $application);
            push @{$results{$sub_application}}, [$jobname, 'VARIABLE %%LIBMEMSYM', $var_value, 'Le dernier élément du chemin dans %%LIBMEMSYM doit inclure le nom de l\'APPLICATION du JOB', $is_conform];
        }
    }
    
    # Vérification WEEKSCAL ou DAYSCAL
    foreach my $calendar ($job->findnodes('./WEEKSCAL | ./DAYSCAL')) {
        my $cal_value = $calendar->findvalue('@VALUE');
        my $is_conform = ($cal_value =~ /^(G-|S-|P-|STANDARD)$/);
        push @{$results{$sub_application}}, [$jobname, 'CALENDAR', $cal_value, 'La valeur de WEEKSCAL ou DAYSCAL doit commencer par G-, S-, P- ou être STANDARD', $is_conform];
    }

    # Vérification de la balise QUANTITATIVE
    foreach my $quantitative ($job->findnodes('./QUANTITATIVE')) {
        my $quant_name = $quantitative->findvalue('@NAME');
        my $is_conform = ($quant_name =~ /^QR-/);
        push @{$results{$sub_application}}, [$jobname, 'QUANTITATIVE', $quant_name, 'Le NAME de QUANTITATIVE doit commencer par QR-', $is_conform];
    }
}

# Calcul du pourcentage de conformité pour toutes les vérifications
my $total_checks_all = 0;
my $total_conform_all = 0;
foreach my $sub_app (keys %results) {
    foreach my $row (@{$results{$sub_app}}) {
        my $status = $row->[4];
        $total_checks_all++;
        $total_conform_all++ if $status;
    }
}

my $percent_conform = $total_checks_all > 0 ? int(($total_conform_all / $total_checks_all) * 100) : 0;

# Génération HTML
my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
print "<html><body>";
print "<h1>Homologation chaine Control-M : $folder_name</h1>";
print "<p>Généré le : $timestamp</p>";
print "<p>FOLDER_ORDER_METHOD : $folder_order_method " . ($folder_order_valid ? '✔️ Conforme' : '❌ Non conforme') . "</p>";

foreach my $sub_app (keys %results) {
    print "<h2>Vérifications pour SUB_APPLICATION: $sub_app</h2>";
    print "<table border='1'><tr><th>JOBNAME</th><th>Champ</th><th>Valeur</th><th>Règle</th><th>Conformité</th></tr>";
    
    my $last_jobname = '';
    my $row_color = 0; # Variable pour alterner les couleurs des lignes selon JOBNAME
    
    foreach my $row (@{$results{$sub_app}}) {
        my ($jobname, $field, $value, $rule, $status) = @$row;
        
        # Si le JOBNAME change, alterner la couleur de fond
        if ($jobname ne $last_jobname) {
            $row_color = ($row_color % 2 == 0) ? 1 : 0;
            $last_jobname = $jobname;
        }
        
        my $color = $status ? 'green' : 'red';
        my $bg_color = ($row_color == 0) ? '#f2f2f2' : 'powderblue'; # Alternance clair/sombre
        print "<tr style='background-color:$bg_color;'><td>$jobname</td><td>$field</td><td>$value</td><td>$rule</td><td style='color:$color;'>" . ($status ? 'Conforme' : 'Non conforme') . "</td></tr>";
    }
    print "</table>";
}

# Affichage du récapitulatif de la conformité globale
print "<h3>Conformité globale</h3>";
print "<p>Conformité totale : $total_conform_all / $total_checks_all (" . $percent_conform . "%)</p>";

# Log dans le fichier homol.log
open my $log_fh, '>>', 'homol.log' or die "Impossible d'ouvrir homol.log: $!\n";
print $log_fh strftime("%Y-%m-%d %H:%M:%S", localtime) . " - $folder_name - Conformité : $percent_conform%\n";
close $log_fh;

print "</body></html>";
