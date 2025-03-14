#!/bin/bash

# Définition des gardes sous forme de fonctions
lv_exists() { [ -e "/dev/vg1/lv1" ]; }  # Vérifie si le LV existe
fstab_updated() { grep -q "/mnt/data" /etc/fstab; }  # Vérifie si fstab est mis à jour
config_updated() { grep -q "config_ok" /etc/app/config.conf; }  # Vérifie la modif du fichier de config
service_running() { systemctl is-active --quiet myservice; }  # Vérifie si le service est actif

# Boucle principale qui respecte l'esprit du GCL
while :; do
    case true in
        # Création du LV et du FS si non existant
        "$(lv_exists)")
            echo "[OK] LV existe déjà" ;;
        *)
            echo "[INFO] Création du LV et du FS..."
            lvcreate -L 10G -n lv1 vg1 && mkfs.ext4 /dev/vg1/lv1 && mkdir -p /mnt/data
            continue ;;  # Recommencer la boucle
    esac

    case true in
        # Ajout dans fstab
        "$(fstab_updated)")
            echo "[OK] fstab déjà mis à jour" ;;
        *)
            echo "[INFO] Mise à jour de fstab..."
            echo "/dev/vg1/lv1 /mnt/data ext4 defaults 0 2" >> /etc/fstab && mount -a
            continue ;;
    esac

    case true in
        # Modification du fichier de config
        "$(config_updated)")
            echo "[OK] Fichier de config déjà modifié" ;;
        *)
            echo "[INFO] Modification du fichier de config..."
            echo "config_ok" >> /etc/app/config.conf
            continue ;;
    esac

    case true in
        # Relancer le service
        "$(service_running)")
            echo "[OK] Service déjà actif" ;;
        *)
            echo "[INFO] Redémarrage du service..."
            systemctl restart myservice
            continue ;;
    esac

    # Si toutes les actions sont effectuées avec succès, on sort
    echo "[SUCCESS] Toutes les étapes ont été exécutées correctement."
    break
done
