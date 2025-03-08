### Vérifier si un fichier existe avant de le créer
if [ ! -f "fichier.txt" ]; then touch "fichier.txt"; fi

### Vérifier si un répertoire existe avant de le créer
if [ ! -d "/chemin/du/repertoire" ]; then mkdir -p "/chemin/du/repertoire"; fi

### Vérifier si un paquet est déjà installé avant de l’installer
if ! dpkg -l | grep -q "nom_du_paquet"; then sudo apt-get install -y nom_du_paquet; fi

### Vérifier si un service est déjà en cours avant de le démarrer
if ! systemctl is-active --quiet nom_du_service; then sudo systemctl start nom_du_service; fi

### Vérifier si un processus est en cours avant de le tuer
if pgrep -x "mon_processus" > /dev/null; then killall mon_processus; fi

### Vérifier si un fichier est vide avant de l’écrire
if [ ! -s "fichier.txt" ]; then echo "Contenu initial" > fichier.txt; fi

### Vérifier si un mot existe dans un fichier avant de l’ajouter
if ! grep -q "mot_a_ajouter" fichier.txt; then echo "mot_a_ajouter" >> fichier.txt; fi

### Vérifier si une variable est définie avant de l’utiliser
if [ -z "$ma_variable" ]; then ma_variable="valeur_defaut"; fi

### Vérifier si une valeur est dans un tableau avant de l’ajouter
if [[ ! " ${tableau[@]} " =~ "valeur" ]]; then tableau+=("valeur"); fi

### 
