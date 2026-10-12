# Face Hugger - dossier préparatoire ANSSI

Version 1.0 (build 3) | Préparé le 30 septembre 2026

BROUILLON NON SIGNÉ - aucune déclaration n'a été envoyée à l'ANSSI. Ce dossier rassemble des faits techniques et des propositions de rédaction. Il ne constitue ni une autorisation, ni une décision de classement, ni un avis juridique.

## Objet et état actuel

Face Hugger est un logiciel macOS de gestion de transferts de fichiers vers Hugging Face. La distribution prévue est gratuite, dans tous les territoires de l'App Store, France incluse. Le logiciel contient des bibliothèques tierces de chiffrement utilisées pour les connexions HTTPS/TLS.

Une fiche de chiffrement a été créée dans App Store Connect : deb48a27-898e-44dc-8da5-77c2cf681899. Réponses enregistrées : cryptographie tierce oui ; algorithmes propriétaires non ; disponibilité en France oui. État Apple : CREATED, exempt=false. Aucune pièce justificative n'est téléversée et aucun code d'approbation n'a été fourni. Le questionnaire Apple exige explicitement un formulaire d'approbation de déclaration de chiffrement français ; le présent brouillon ne le remplace pas.

Le build 3 est marqué usesNonExemptEncryption=true. La commande d'association a annoncé un succès, mais la relecture de la relation ne montre aucun build associé. La conformité n'est donc pas résolue.

## Contenu du dossier

- Le formulaire officiel ANSSI original, conservé sans modification, est fourni séparément sous le nom ANSSI-formulaire-officiel-XFA.pdf.
- Les pages suivantes constituent une fiche de préparation pour les rubriques du formulaire.
- La description technique décrit les composants réellement distribués et distingue les capacités des bibliothèques des paramètres négociés sur une connexion réelle.
- Le guide public du produit et le code source sont accessibles sur https://github.com/bubstackdev/face-hugger.

## Limite du formulaire officiel

Le PDF officiel utilise XFA dynamique. Les lecteurs courants peuvent afficher seulement une page demandant Adobe Reader. Ouvrir le fichier original dans un lecteur compatible XFA. Le présent dossier ne remplace pas ce formulaire et ne prétend pas en avoir rempli les champs.

---PAGE---

# Fiche de préparation du formulaire

## Nature de la démarche et rubrique A

La case de démarche (déclaration, autorisation, démarche combinée) doit être choisie par le déclarant après vérification du régime applicable. Aucune case n'a été cochée pour son compte.

A.1 / A.2 - Confirmer si le déclarant est une personne physique ou une personne morale. Ne pas présumer qu'un compte développeur individuel constitue une entreprise enregistrée.

- Identité connue du propriétaire du projet : Zak Keown. À confirmer comme identité légale à utiliser dans le dossier.
- Contact public du produit : support@bubstack.dev. À confirmer comme contact administratif et technique.
- À compléter localement : nationalité, adresse postale complète, téléphone de contact et qualité du signataire.
- Si personne morale : dénomination légale, pays, numéro d'enregistrement pertinent et justificatif requis. Ne pas inventer de numéro SIRET pour une entité étrangère.

Les coordonnées privées fournies pour App Review ne sont pas reproduites dans ce dossier public ni réutilisées comme autorisation de transmission à une administration.

## B.1 - Identification du moyen

- Dénomination proposée : Face Hugger.
- Marque de distribution proposée : Face Hugger.
- Référence commerciale : Face Hugger pour macOS, identifiant dev.zakkeown.FaceHugger.
- Version : 1.0, build 3, architectures arm64 et x86_64.
- Fabricant / développeur : identité du déclarant à confirmer.
- Date de mise sur le marché : à compléter ; aucune date publique n'est fixée et l'application n'a pas été soumise à App Review.

## B.2 - Fonction principale

Catégorie technique proposée : logiciel. Fonction principale proposée : envoi, stockage et réception d'informations, et plus précisément préparation de dossiers locaux, consultation de dépôts et téléversement vers Hugging Face.

Le chiffrement protège les communications nécessaires à ces fonctions ; Face Hugger ne propose pas d'interface de VPN, de gestion d'autorité de certification ni de chiffrement arbitraire de fichiers.

---PAGE---

# Points à finaliser avant toute signature

## B.3 et C - Cryptographie et classement

B.3.1 à B.3.4 : utiliser la description technique jointe. Les fonctions identifiées sont la confidentialité, l'intégrité et l'authentification du serveur dans les connexions TLS. Le jeton Hugging Face sert à l'autorisation applicative. Les suites offertes par une bibliothèque ne prouvent pas la suite négociée à chaque transfert.

La rubrique C contient une déclaration de classement "grand public". Elle est laissée non cochée. Les éléments factuels utilisables pour l'examiner sont : distribution gratuite par l'App Store, installation autonome, bibliothèques incluses et absence de réglage utilisateur des algorithmes dans l'interface. La présence du code source public et des bibliothèques doit aussi être prise en compte par le déclarant ; ce dossier ne tranche pas le classement.

## D, E et F - Historique, pièces, attestation

Aucune autorisation antérieure n'a été fournie. Vérifier la rubrique D avant de la considérer sans objet.

Pour E : vérifier les pièces réellement jointes et leur applicabilité à la personne physique ou morale. Le dossier technique est préparé ; la présentation du déclarant et tout justificatif d'enregistrement éventuel restent à fournir. Le README public décrit l'usage du produit. Un paquet signé peut être fourni sur demande, sous réserve du mode de distribution approprié.

Pour F : compléter la qualité du signataire, la date et la signature seulement après vérification de l'ensemble des réponses et des pièces. Aucune signature ni attestation n'a été apposée automatiquement.

## Transmission à effectuer par le propriétaire

La page officielle ANSSI indique une transmission à controle@ssi.gouv.fr avec l'objet contenant [formalités] suivi de la marque et du nom du produit. Elle demande le formulaire électronique complété, une copie complétée signée et scannée, et les documents nécessaires. Vérifier les instructions actuelles avant l'envoi. Aucun message n'a été envoyé dans cette préparation.

Objet proposé : [formalités] Face Hugger - Face Hugger

Après retour de l'autorité compétente, téléverser dans App Store Connect la pièce effectivement requise par Apple, attendre l'examen, puis vérifier l'association au build. Ne pas téléverser ce brouillon comme s'il s'agissait d'une autorisation.

## Sources officielles

ANSSI, formulaires : https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/

Apple, documentation de chiffrement : https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/

Ces pages ont été consultées le 30 septembre 2026. Leurs exigences sont résumées, sans préjuger d'une exemption ou d'une décision administrative.
