### convert
# installation
xxx install python3-xmltodict 

### convert 
cat fichier.xml | python3 -c 'import sys, xmltodict, json; print(json.dumps(xmltodict.parse(sys.stdin.read()), indent=2))' | jq '.'

### convert csv to json
nom,age,ville
Alice,25,Paris
Bob,30,Lyon

jq -R -s 'split("\n") | .[1:] | map(split(",") | {nom: .[0], age: .[1], ville: .[2]})' fichier.csv
