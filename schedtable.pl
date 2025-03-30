### learning perl to extract xml in schedtable.xml 
use strict;
use warnings;
use XML::LibXML;

my $parser = XML::LibXML->new();
my $doc = $parser->load_xml(location => 'schedtable.xml');

my %folder_names;
foreach my $folder ($doc->findnodes('//FOLDER')) {
    my $folder_name = $folder->findvalue('@FOLDER_NAME');
    foreach my $job ($folder->findnodes('.//JOB')) {
        $folder_names{$job->findvalue('@JOBNAME')} = $folder_name;
    }
}

my (%results, %stats);
my $total_checks = 0;
my $total_conform = 0;

foreach my $job ($doc->findnodes('//JOB')) {
    my $jobname = $job->findvalue('@JOBNAME');
    my $application = $job->findvalue('@APPLICATION');
    my $sub_application = $job->findvalue('@SUB_APPLICATION');
    my $nodeid = $job->findvalue('@NODEID');
    my $folder_name = $folder_names{$jobname} // '';
    
    $results{$sub_application} //= [];
    $stats{$sub_application}{total} = 0;
    $stats{$sub_application}{conform} = 0;

    push @{$results{$sub_application}}, [$jobname, 'JOBNAME', $jobname, 'Nom du job', 1];

    if (defined $application) {
        my $is_conform = (defined $folder_name && $application eq $folder_name && length($application) == 9);
        push @{$results{$sub_application}}, [$jobname, 'APPLICATION', $application, 'APPLICATION doit être égal à FOLDER_NAME et 9 caractères', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    if (defined $nodeid && $nodeid ne '') {
        my $is_conform = (length($nodeid) == 10 && uc($nodeid) eq $nodeid);
        push @{$results{$sub_application}}, [$jobname, 'NODEID', $nodeid, 'NODEID doit être en majuscule et 10 caractères', $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    foreach my $incond ($job->findnodes('./INCOND')) {
        my $cond_name = $incond->findvalue('@NAME');
        my $rule = 'Nom INCOND doit avoir les 9 premiers caractères identiques à APPLICATION';
        my $is_conform = (defined $cond_name && defined $application && substr($cond_name, 0, 9) eq $application);
        push @{$results{$sub_application}}, [$jobname, 'INCOND', $cond_name, $rule, $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    foreach my $outcond ($job->findnodes('./OUTCOND')) {
        my $cond_name = $outcond->findvalue('@NAME');
        my $rule = 'Nom OUTCOND doit commencer par APPLICATION + JOBNAME + suffixe valide';
        my $is_conform = (defined $cond_name && defined $application && defined $jobname && $cond_name =~ /^${application}${jobname}-(OK|KO|ER|C[0-9]|LO|ENDED)$/);
        push @{$results{$sub_application}}, [$jobname, 'OUTCOND', $cond_name, $rule, $is_conform];
        $stats{$sub_application}{total}++;
        $stats{$sub_application}{conform}++ if $is_conform;
    }
    
    $total_checks += $stats{$sub_application}{total};
    $total_conform += $stats{$sub_application}{conform};
}

print "<html><body>";

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

print "</body></html>";
