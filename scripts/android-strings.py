#!/usr/bin/env python3
"""Writes android/app/src/main/res/values-<lang>/strings.xml from the English Android strings, taking each
translation from the iPhone app (ios/Resources/Localizable.xcstrings) when the English text matches an iPhone key
("phone" matched against "iPhone"), else from ANDROID_ONLY below. Prints any string still missing a translation."""
import json, pathlib, re, sys, xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
LANGS = {"de": "de", "es": "es", "fr": "fr", "it": "it", "pt-BR": "pt-rBR"}
PHONE = {"de": [("dieses iPhone", "dieses Handy"), ("diesem iPhone", "diesem Handy"), ("iPhone", "Handy")],
         "es": [("iPhone", "teléfono")],
         "fr": [("cet iPhone", "ce téléphone"), ("Cet iPhone", "Ce téléphone"), ("l’iPhone", "le téléphone"), ("l'iPhone", "le téléphone"), ("iPhone", "téléphone")],
         "it": [("iPhone", "telefono")],
         "pt-BR": [("iPhone", "celular")]}
# Strings with no iPhone equivalent (or reworded for Android).
ANDROID_ONLY = {
    "brand_tv_notice": {
        "de": "Die TV-Einrichtung und Purios Startbildschirm funktionieren auf Android TV und Google TV. Auf diesem Fernseher ist Purio die Fernbedienung: Tasten, Apps und Tippen.",
        "es": "La configuración de la TV y la pantalla de inicio de Purio funcionan en Android TV y Google TV. En esta TV, Purio es el mando: teclas, apps y escritura.",
        "fr": "La configuration de la TV et l’écran d’accueil de Purio fonctionnent sur Android TV et Google TV. Sur cette TV, Purio est la télécommande : touches, apps et saisie.",
        "it": "La configurazione della TV e la schermata Home di Purio funzionano su Android TV e Google TV. Su questa TV Purio è il telecomando: tasti, app e digitazione.",
        "pt-BR": "A configuração da TV e a tela inicial do Purio funcionam em Android TV e Google TV. Nesta TV, o Purio é o controle: teclas, apps e digitação."},
    "cant_see_photos_detail": {
        "de": "Um Fotos und Videos auf deinem Fernseher zu zeigen, erlaube Purio TV in den Einstellungen den Zugriff auf Fotos und Videos. Sie werden auf diesem Handy gelesen und nur an deinen Fernseher gesendet.",
        "es": "Para mostrar fotos y vídeos en tu tele, permite a Purio TV acceder a fotos y vídeos en Ajustes. Se leen en este teléfono y solo se envían a tu tele.",
        "fr": "Pour afficher vos photos et vidéos sur votre TV, autorisez Purio TV à accéder aux photos et vidéos dans les Paramètres. Elles sont lues sur ce téléphone et envoyées uniquement à votre TV.",
        "it": "Per mostrare foto e video sulla TV, consenti a Purio TV l’accesso a foto e video nelle Impostazioni. Vengono letti su questo telefono e inviati solo alla tua TV.",
        "pt-BR": "Para mostrar fotos e vídeos na sua TV, permita que o Purio TV acesse fotos e vídeos nas Configurações. Eles são lidos neste celular e enviados só para a sua TV."},
    "soon_tv": {
        "de": "Dein TV-Startbildschirm (Apps, Hintergrund, Look, Wetter, Sleep-Timer) und die TV-Einrichtung kommen bald zu Purio TV für Android. Nutze dafür bis dahin die iPhone-App.",
        "es": "Tu pantalla de inicio de la TV (apps, fondo, estilo, tiempo, temporizador) y la configuración de la TV llegarán pronto a Purio TV para Android. Mientras tanto, usa la app de iPhone.",
        "fr": "Votre écran d’accueil TV (apps, fond d’écran, style, météo, minuterie) et la configuration de la TV arrivent bientôt sur Purio TV pour Android. D’ici là, utilisez l’app iPhone.",
        "it": "La schermata Home della TV (app, sfondo, stile, meteo, timer) e la configurazione della TV arriveranno presto su Purio TV per Android. Nel frattempo usa l’app per iPhone.",
        "pt-BR": "A tela inicial da TV (apps, papel de parede, visual, clima, timer) e a configuração da TV chegam em breve ao Purio TV para Android. Até lá, use o app para iPhone."},
    "soon_actions": {
        "de": "Aktionen, Widgets und Schnelleinstellungen kommen bald zu Purio TV für Android.",
        "es": "Las acciones, los widgets y los ajustes rápidos llegarán pronto a Purio TV para Android.",
        "fr": "Les actions, widgets et réglages rapides arrivent bientôt sur Purio TV pour Android.",
        "it": "Azioni, widget e impostazioni rapide arriveranno presto su Purio TV per Android.",
        "pt-BR": "Ações, widgets e configurações rápidas chegam em breve ao Purio TV para Android."},
    "volume_title": {"de": "Lautstärke", "es": "Volumen", "fr": "Volume", "it": "Volume", "pt-BR": "Volume"},
    "problem_connect_failed": {
        "de": "Keine Verbindung zum gekoppelten Fernseher. Prüfe WLAN und ob der Fernseher eingeschaltet ist.",
        "es": "No se pudo conectar con la TV vinculada. Revisa el Wi-Fi y que la TV esté encendida.",
        "fr": "Connexion impossible à la TV associée. Vérifiez le Wi-Fi et que la TV est allumée.",
        "it": "Impossibile connettersi alla TV abbinata. Controlla il Wi-Fi e che la TV sia accesa.",
        "pt-BR": "Não foi possível conectar à TV pareada. Verifique o Wi-Fi e se a TV está ligada."},
    "problem_other": {"de": "Etwas ist schiefgelaufen. Versuche es erneut.", "es": "Algo salió mal. Inténtalo de nuevo.",
                      "fr": "Un problème est survenu. Réessayez.", "it": "Qualcosa è andato storto. Riprova.", "pt-BR": "Algo deu errado. Tente novamente."},
    "tab_actions": {"de": "Aktionen", "es": "Acciones", "fr": "Actions", "it": "Azioni", "pt-BR": "Ações"},
    "address_hint": {
        "de": "Du findest sie am Fernseher unter Einstellungen › Netzwerk und Internet, beim WLAN-Netz.",
        "es": "Está en la TV, en Ajustes › Red e Internet, en la red Wi-Fi.",
        "fr": "Elle se trouve sur la TV dans Paramètres › Réseau et Internet, sous le réseau Wi-Fi.",
        "it": "La trovi sulla TV in Impostazioni › Rete e Internet, sotto la rete Wi-Fi.",
        "pt-BR": "Ela fica na TV em Configurações › Rede e Internet, na rede Wi-Fi."},
    "address_label": {"de": "IP-Adresse", "es": "Dirección IP", "fr": "Adresse IP", "it": "Indirizzo IP", "pt-BR": "Endereço IP"},
    "address_connect": {"de": "Verbinden", "es": "Conectar", "fr": "Se connecter", "it": "Connetti", "pt-BR": "Conectar"},
    "no_tv": {"de": "Kein Fernseher", "es": "Ninguna TV", "fr": "Aucune TV", "it": "Nessuna TV", "pt-BR": "Nenhuma TV"},
    "forget_tv": {"de": "Anderen Fernseher verbinden", "es": "Conectar otra TV", "fr": "Connecter une autre TV", "it": "Connetti un’altra TV", "pt-BR": "Conectar outra TV"},
    "forget_title": {"de": "%1$s vergessen?", "es": "¿Olvidar %1$s?", "fr": "Oublier %1$s ?", "it": "Dimenticare %1$s?", "pt-BR": "Esquecer %1$s?"},
    "forget_message": {
        "de": "Dieses Handy vergisst den Fernseher. Um ihn wieder zu nutzen, kopple ihn mit einem neuen Code.",
        "es": "Este teléfono olvida la TV. Para volver a usarla, vincúlala con un código nuevo.",
        "fr": "Ce téléphone oublie la TV. Pour l’utiliser à nouveau, associez-la avec un nouveau code.",
        "it": "Questo telefono dimentica la TV. Per usarla di nuovo, abbinala con un nuovo codice.",
        "pt-BR": "Este celular esquece a TV. Para usá-la de novo, pareie com um novo código."},
    "forget_confirm": {"de": "Vergessen", "es": "Olvidar", "fr": "Oublier", "it": "Dimentica", "pt-BR": "Esquecer"},
    "about": {"de": "Info", "es": "Acerca de", "fr": "À propos", "it": "Info", "pt-BR": "Sobre"},
    "about_detail": {"de": "Purio TV %1$s · Android TV Fernbedienung &amp; Steuerung", "es": "Purio TV %1$s · Mando y control de Android TV",
                     "fr": "Purio TV %1$s · Télécommande et contrôle Android TV", "it": "Purio TV %1$s · Telecomando e controllo Android TV",
                     "pt-BR": "Purio TV %1$s · Controle remoto para Android TV"},
    "key_inputs": {"de": "Eingänge", "es": "Entradas", "fr": "Entrées", "it": "Ingressi", "pt-BR": "Entradas"},
    "key_up": {"de": "Hoch", "es": "Arriba", "fr": "Haut", "it": "Su", "pt-BR": "Para cima"},
    "key_down": {"de": "Runter", "es": "Abajo", "fr": "Bas", "it": "Giù", "pt-BR": "Para baixo"},
    "key_left": {"de": "Links", "es": "Izquierda", "fr": "Gauche", "it": "Sinistra", "pt-BR": "Esquerda"},
    "key_right": {"de": "Rechts", "es": "Derecha", "fr": "Droite", "it": "Destra", "pt-BR": "Direita"},
    "key_select": {"de": "OK", "es": "OK", "fr": "OK", "it": "OK", "pt-BR": "OK"},
    "key_volume_up": {"de": "Lauter", "es": "Subir volumen", "fr": "Volume +", "it": "Volume su", "pt-BR": "Aumentar volume"},
    "remove": {"de": 'Entfernen', "es": 'Quitar', "fr": 'Retirer', "it": 'Rimuovi', "pt-BR": 'Remover'},
    "fewer": {"de": 'Weniger', "es": 'Menos', "fr": 'Moins', "it": 'Meno', "pt-BR": 'Menos'},
    "more": {"de": 'Mehr', "es": 'Más', "fr": 'Plus', "it": 'Più', "pt-BR": 'Mais'},
    "undo": {"de": 'Rückgängig', "es": 'Deshacer', "fr": 'Annuler', "it": 'Annulla', "pt-BR": 'Desfazer'},
    "edit_named": {"de": '%1$s bearbeiten', "es": 'Editar %1$s', "fr": 'Modifier %1$s', "it": 'Modifica %1$s', "pt-BR": 'Editar %1$s'},
    "export_named": {"de": '%1$s exportieren', "es": 'Exportar %1$s', "fr": 'Exporter %1$s', "it": 'Esporta %1$s', "pt-BR": 'Exportar %1$s'},
    "add_named": {"de": '%1$s hinzufügen', "es": 'Añadir %1$s', "fr": 'Ajouter %1$s', "it": 'Aggiungi %1$s', "pt-BR": 'Adicionar %1$s'},
    "new_device": {"de": 'Neues Gerät', "es": 'Nuevo dispositivo', "fr": 'Nouvel appareil', "it": 'Nuovo dispositivo', "pt-BR": 'Novo dispositivo'},
    "language_detail": {"de": 'Folgt deinem Handy. Wähle in den Android-Einstellungen eine andere Sprache für diese App.', "es": 'Sigue a tu teléfono. Elige otro idioma para esta app en los Ajustes de Android.', "fr": 'Suit votre téléphone. Choisissez une autre langue pour cette app dans les Paramètres Android.', "it": 'Segue il telefono. Scegli un’altra lingua per questa app nelle Impostazioni di Android.', "pt-BR": 'Segue o celular. Escolha outro idioma para este app nas Configurações do Android.'},
    "backup_before_restoring": {"de": 'Vor dem Wiederherstellen', "es": 'Antes de restaurar', "fr": 'Avant la restauration', "it": 'Prima del ripristino', "pt-BR": 'Antes de restaurar'},
    "home_backup_name": {"de": '%1$s · Home-Backup', "es": '%1$s · Copia de Inicio', "fr": '%1$s · Sauvegarde de l’accueil', "it": '%1$s · Backup della Home', "pt-BR": '%1$s · Backup da tela inicial'},
    "backup_before_loading": {"de": 'Vor dem Laden des TV-Layouts', "es": 'Antes de cargar el diseño de la TV', "fr": 'Avant de charger la disposition de la TV', "it": 'Prima di caricare il layout della TV', "pt-BR": 'Antes de carregar o layout da TV'},
    "photo_load_failed": {"de": 'Dieses Foto konnte nicht geladen werden', "es": 'No se pudo cargar esta foto', "fr": 'Impossible de charger cette photo', "it": 'Impossibile caricare questa foto', "pt-BR": 'Não foi possível carregar esta foto'},
    "tap_try_again": {"de": 'Tippe auf „Erneut versuchen“, um neu zu verbinden.', "es": 'Toca Reintentar para volver a conectar.', "fr": 'Touchez Réessayer pour vous reconnecter.', "it": 'Tocca Riprova per riconnetterti.', "pt-BR": 'Toque em Tentar de novo para reconectar.'},
    "tv_no_wallpaper": {"de": 'Der Fernseher hat sein Hintergrundbild nicht mitgeschickt. Aktualisiere, bevor du dieses Layout lädst.', "es": 'La TV no envió su fondo. Actualiza antes de cargar este diseño.', "fr": 'La TV n’a pas envoyé son fond d’écran. Actualisez avant de charger cette disposition.', "it": 'La TV non ha inviato il suo sfondo. Aggiorna prima di caricare questo layout.', "pt-BR": 'A TV não enviou o papel de parede. Atualize antes de carregar este layout.'},
    "hidden_on_tv": {"de": 'Ausgeblendet', "es": 'Oculta', "fr": 'Masquée', "it": 'Nascosta', "pt-BR": 'Oculto'},
    "apps_order_footer": {"de": 'Mit den Pfeilen sortierst du um. Ausblenden ändert nur das Home-Layout; Deinstallieren braucht einen verbundenen Fernseher und eine Bestätigung auf seinem Bildschirm.', "es": 'Usa las flechas para reordenar. Ocultar solo cambia el diseño de Inicio; desinstalar requiere una TV conectada y confirmarlo en su pantalla.', "fr": 'Utilisez les flèches pour réorganiser. Masquer ne change que la disposition de l’accueil ; désinstaller nécessite une TV connectée et une confirmation à l’écran.', "it": 'Usa le frecce per riordinare. Nascondere cambia solo il layout della Home; disinstallare richiede una TV connessa e la conferma sul suo schermo.', "pt-BR": 'Use as setas para reordenar. Ocultar muda só o layout da tela inicial; desinstalar exige a TV conectada e a confirmação na tela dela.'},
    "new_action": {"de": 'Neue Aktion', "es": 'Nueva acción', "fr": 'Nouvelle action', "it": 'Nuova azione', "pt-BR": 'Nova ação'},
    "quick_access": {"de": 'Schnellzugriff', "es": 'Acceso rápido', "fr": 'Accès rapide', "it": 'Accesso rapido', "pt-BR": 'Acesso rápido'},
    "widgets_and_tile": {"de": 'Widgets & Schnelleinstellungen', "es": 'Widgets y ajustes rápidos', "fr": 'Widgets et réglages rapides', "it": 'Widget e impostazioni rapide', "pt-BR": 'Widgets e configurações rápidas'},
    "widgets_hint": {"de": 'Für die Steuerung mit einem Tippen füge Purio TV aus der Widget-Liste deines Startbildschirms hinzu oder seine Kachel zu den Schnelleinstellungen.', "es": 'Para controlarla con un toque, añade Purio TV desde la lista de widgets de tu pantalla de inicio, o su botón a los ajustes rápidos.', "fr": 'Pour un contrôle en un geste, ajoutez Purio TV depuis la liste des widgets de votre écran d’accueil, ou sa vignette aux réglages rapides.', "it": 'Per il controllo con un tocco, aggiungi Purio TV dall’elenco widget della schermata Home, o il suo riquadro alle impostazioni rapide.', "pt-BR": 'Para controlar com um toque, adicione o Purio TV pela lista de widgets da tela inicial ou o bloco dele às configurações rápidas.'},
    "widget_remote": {"de": 'Fernbedienungs-Widget', "es": 'Widget de mando', "fr": 'Widget télécommande', "it": 'Widget telecomando', "pt-BR": 'Widget de controle'},
    "widget_remote_detail": {"de": 'Pfeile, OK, Zurück, Home und Ein/Aus auf deinem Startbildschirm', "es": 'Flechas, OK, Atrás, Inicio y encendido en tu pantalla de inicio', "fr": 'Flèches, OK, Retour, Accueil et marche/arrêt sur votre écran d’accueil', "it": 'Frecce, OK, Indietro, Home e accensione nella schermata Home', "pt-BR": 'Setas, OK, Voltar, Início e liga/desliga na tela inicial'},
    "widget_actions": {"de": 'Schnellaktionen-Widget', "es": 'Widget de acciones rápidas', "fr": 'Widget d’actions rapides', "it": 'Widget azioni rapide', "pt-BR": 'Widget de ações rápidas'},
    "widget_actions_detail": {"de": 'Deine ersten vier Schnellaktionen, je ein Tippen', "es": 'Tus primeras cuatro acciones rápidas, un toque cada una', "fr": 'Vos quatre premières actions rapides, un geste chacune', "it": 'Le tue prime quattro azioni rapide, un tocco ciascuna', "pt-BR": 'Suas quatro primeiras ações rápidas, um toque cada'},
    "tile_power": {"de": 'Kachel TV ein/aus', "es": 'Botón de encendido de la TV', "fr": 'Vignette marche/arrêt TV', "it": 'Riquadro accensione TV', "pt-BR": 'Bloco liga/desliga da TV'},
    "tile_power_detail": {"de": 'In den Schnelleinstellungen: weckt den Fernseher oder schaltet ihn aus', "es": 'En los ajustes rápidos: enciende la TV o la apaga', "fr": 'Dans les réglages rapides : réveille la TV ou l’éteint', "it": 'Nelle impostazioni rapide: riattiva la TV o la spegne', "pt-BR": 'Nas configurações rápidas: liga a TV ou desliga'},
    "app_shortcuts": {"de": 'Verknüpfungen am App-Symbol', "es": 'Accesos directos del icono', "fr": 'Raccourcis de l’icône', "it": 'Scorciatoie dell’icona', "pt-BR": 'Atalhos do ícone'},
    "app_shortcuts_detail": {"de": 'Halte das Purio-TV-Symbol gedrückt: TV einschalten, TV ausschalten, Netflix, YouTube, TV pausieren', "es": 'Mantén pulsado el icono de Purio TV: Encender TV, Apagar TV, Netflix, YouTube, Pausar TV', "fr": 'Maintenez l’icône Purio TV : Réveiller la TV, Éteindre la TV, Netflix, YouTube, Mettre la TV en pause', "it": 'Tieni premuta l’icona di Purio TV: Accendi TV, Spegni TV, Netflix, YouTube, Metti in pausa la TV', "pt-BR": 'Toque e segure o ícone do Purio TV: Ligar TV, Desligar TV, Netflix, YouTube, Pausar TV'},
    "quick_access_footer": {"de": 'Jedes Tippen öffnet eine kurze Verbindung zum gekoppelten Fernseher im lokalen Netz, sendet den Befehl und schließt sie. Im Hintergrund läuft nichts weiter.', "es": 'Cada toque abre una conexión breve con la TV vinculada en tu red local, envía la orden y la cierra. Nada sigue funcionando en segundo plano.', "fr": 'Chaque geste ouvre une courte connexion avec la TV associée sur votre réseau local, envoie la commande puis la ferme. Rien ne reste actif en arrière-plan.', "it": 'Ogni tocco apre una breve connessione con la TV abbinata sulla rete locale, invia il comando e la chiude. Nulla resta attivo in background.', "pt-BR": 'Cada toque abre uma conexão curta com a TV pareada na rede local, envia o comando e fecha. Nada fica rodando em segundo plano.'},
    "turn_off_at": {"de": 'Ausschalten um %1$s', "es": 'Apagar a las %1$s', "fr": 'Extinction à %1$s', "it": 'Spegnimento alle %1$s', "pt-BR": 'Desligar às %1$s'},
    "no_confirmed_timer": {"de": 'Kein bestätigter Timer', "es": 'Ningún temporizador confirmado', "fr": 'Aucune minuterie confirmée', "it": 'Nessun timer confermato', "pt-BR": 'Nenhum timer confirmado'},
    "benefit_tested_list": {"de": 'Eine getestete Liste für dein TV-Modell', "es": 'Una lista probada para tu modelo de TV', "fr": 'Une liste testée pour votre modèle de TV', "it": 'Un elenco testato per il tuo modello di TV', "pt-BR": 'Uma lista testada para o seu modelo de TV'},
    "benefit_undo": {"de": 'Nichts wird gelöscht. Jederzeit rückgängig', "es": 'No se borra nada. Puedes deshacerlo cuando quieras', "fr": 'Rien n’est supprimé. Annulable à tout moment', "it": 'Nulla viene eliminato. Annulli quando vuoi', "pt-BR": 'Nada é apagado. Desfaça quando quiser'},
    "benefit_no_computer": {"de": 'Kein Computer nötig, etwa 10 Minuten', "es": 'Sin ordenador, unos 10 minutos', "fr": 'Sans ordinateur, environ 10 minutes', "it": 'Nessun computer, circa 10 minuti', "pt-BR": 'Sem computador, cerca de 10 minutos'},
    "apps_deleted": {"de": 'Apps gelöscht', "es": 'apps borradas', "fr": 'app supprimée', "it": 'app eliminate', "pt-BR": 'apps apagados'},
    "anytime": {"de": 'jederzeit', "es": 'cuando quieras', "fr": 'à tout moment', "it": 'quando vuoi', "pt-BR": 'quando quiser'},
    "no_computer": {"de": 'kein Computer', "es": 'sin ordenador', "fr": 'sans ordinateur', "it": 'nessun computer', "pt-BR": 'sem computador'},
    "widget_no_actions": {"de": 'Erstelle eine Schnellaktion in Purio TV', "es": 'Crea una acción rápida en Purio TV', "fr": 'Créez une action rapide dans Purio TV', "it": 'Crea un’azione rapida in Purio TV', "pt-BR": 'Crie uma ação rápida no Purio TV'},
    "tile_label": {"de": 'TV ein/aus', "es": 'Encender TV', "fr": 'TV marche/arrêt', "it": 'Accensione TV', "pt-BR": 'Liga/desliga TV'},
    "su_dev_step1": {"de": 'Öffne am Fernseher Einstellungen › System › Info (bei manchen: Geräteeinstellungen › Info).', "es": 'En la TV, abre Ajustes › Sistema › Información (en algunas: Preferencias del dispositivo › Información).', "fr": 'Sur la TV, ouvrez Paramètres › Système › À propos (sur certaines : Préférences de l’appareil › À propos).', "it": 'Sulla TV apri Impostazioni › Sistema › Informazioni (su alcune: Preferenze dispositivo › Informazioni).', "pt-BR": 'Na TV, abra Configurações › Sistema › Sobre (em algumas: Preferências do dispositivo › Sobre).'},
    "su_dev_step2": {"de": 'Markiere „Build“ (oder „Android TV OS-Build“) und drücke sieben Mal OK auf der Fernbedienung, bis du Entwickler bist.', "es": 'Selecciona «Compilación» (o «Compilación de Android TV OS») y pulsa OK en el mando siete veces, hasta que diga que eres desarrollador.', "fr": 'Sélectionnez « Build » (ou « Build Android TV OS ») et appuyez sept fois sur OK, jusqu’à ce qu’il indique que vous êtes développeur.', "it": 'Evidenzia «Build» (o «Build Android TV OS») e premi OK sul telecomando sette volte, finché dice che sei uno sviluppatore.', "pt-BR": 'Selecione “Build” (ou “Build do Android TV OS”) e aperte OK no controle sete vezes, até aparecer que você é desenvolvedor.'},
    "su_dev_step3": {"de": 'Geh zurück zu Einstellungen › System › Entwickleroptionen. Schalte USB-Debugging ein, und Netzwerk- oder ADB-Debugging, falls dein Fernseher es anzeigt.', "es": 'Vuelve a Ajustes › Sistema › Opciones para desarrolladores. Activa la depuración USB, y la depuración de red o ADB si tu TV la muestra.', "fr": 'Revenez à Paramètres › Système › Options pour les développeurs. Activez le débogage USB, et le débogage réseau ou ADB si votre TV l’affiche.', "it": 'Torna a Impostazioni › Sistema › Opzioni sviluppatore. Attiva il debug USB, e il debug di rete o ADB se la TV lo mostra.', "pt-BR": 'Volte a Configurações › Sistema › Opções do desenvolvedor. Ative a depuração USB, e a depuração de rede ou ADB se a TV mostrar.'},
    "su_dev_step4": {"de": 'Die IP-Adresse des Fernsehers findest du unter Einstellungen › Netzwerk und Internet, bei deiner Verbindung.', "es": 'Busca la dirección IP de la TV en Ajustes › Red e Internet, en tu conexión.', "fr": 'Trouvez l’adresse IP de la TV dans Paramètres › Réseau et Internet, sous votre connexion.', "it": 'Trova l’indirizzo IP della TV in Impostazioni › Rete e Internet, sotto la tua connessione.', "pt-BR": 'Encontre o endereço IP da TV em Configurações › Rede e Internet, na sua conexão.'},
    "su_connect_again": {"de": 'Erneut verbinden', "es": 'Volver a conectar', "fr": 'Se reconnecter', "it": 'Riconnetti', "pt-BR": 'Conectar de novo'},
    "su_dev_profiles": {"de": 'Entwicklungsbuild. Profile in diesem Build: %1$s.', "es": 'Compilación de desarrollo. Perfiles en esta compilación: %1$s.', "fr": 'Build de développement. Profils dans ce build : %1$s.', "it": 'Build di sviluppo. Profili in questa build: %1$s.', "pt-BR": 'Build de desenvolvimento. Perfis neste build: %1$s.'},
    "su_dev_profiles_none": {"de": 'keine (die Profile wurden nicht mitgeliefert)', "es": 'ninguno (no se incluyeron los perfiles)', "fr": 'aucun (les profils n’ont pas été inclus)', "it": 'nessuno (i profili non sono stati inclusi)', "pt-BR": 'nenhum (os perfis não foram incluídos)'},
    "su_export_detail": {"de": 'Er bleibt auch in dieser App gespeichert (Einstellungen › TV-Einrichtung rückgängig machen). Sichere eine Kopie an einem anderen Ort, falls du dieses Handy ersetzt.', "es": 'También se guarda en esta app (Ajustes › Deshacer configuración de la TV). Guarda una copia en otro sitio por si cambias de teléfono.', "fr": 'Il est aussi conservé dans cette app (Réglages › Annuler la configuration TV). Enregistrez-en une copie ailleurs au cas où vous changeriez de téléphone.', "it": 'Resta salvato anche in questa app (Impostazioni › Annulla configurazione TV). Salvane una copia altrove nel caso cambi telefono.', "pt-BR": 'Ele também fica neste app (Ajustes › Desfazer configuração da TV). Salve uma cópia em outro lugar caso troque de celular.'},
    "su_export_failed": {"de": 'Der Wiederherstellungseintrag konnte dort nicht gespeichert werden.', "es": 'No se pudo guardar ahí el registro de recuperación.', "fr": 'Impossible d’enregistrer le fichier de récupération à cet endroit.', "it": 'Impossibile salvare lì il file di ripristino.', "pt-BR": 'Não foi possível salvar o registro de recuperação ali.'},
    "su_secure_step1": {"de": 'Einstellungen › System › Entwickleroptionen: wähle „USB-Debugging-Autorisierungen widerrufen“.', "es": 'Ajustes › Sistema › Opciones para desarrolladores: elige Revocar autorizaciones de depuración USB.', "fr": 'Paramètres › Système › Options pour les développeurs : choisissez Révoquer les autorisations de débogage USB.', "it": 'Impostazioni › Sistema › Opzioni sviluppatore: scegli Revoca autorizzazioni debug USB.', "pt-BR": 'Configurações › Sistema › Opções do desenvolvedor: escolha Revogar autorizações de depuração USB.'},
    "su_secure_step2": {"de": 'Schalte USB-Debugging und Netzwerk- oder ADB-Debugging aus.', "es": 'Desactiva la depuración USB y la depuración de red o ADB.', "fr": 'Désactivez le débogage USB et le débogage réseau ou ADB.', "it": 'Disattiva il debug USB e il debug di rete o ADB.', "pt-BR": 'Desative a depuração USB e a depuração de rede ou ADB.'},
    "su_secure_step3": {"de": 'Starte den Fernseher neu.', "es": 'Reinicia la TV.', "fr": 'Redémarrez la TV.', "it": 'Riavvia la TV.', "pt-BR": 'Reinicie a TV.'},
    "su_the_tv": {"de": 'der Fernseher', "es": 'la TV', "fr": 'la TV', "it": 'la TV', "pt-BR": 'a TV'},
    "su_nothing": {"de": 'nichts', "es": 'nada', "fr": 'rien', "it": 'niente', "pt-BR": 'nada'},
    "su_issue_adb_file_refused": {"de": 'Der Fernseher hat die Datei abgelehnt: %1$s', "es": 'La TV rechazó el archivo: %1$s', "fr": 'La TV a refusé le fichier : %1$s', "it": 'La TV ha rifiutato il file: %1$s', "pt-BR": 'A TV recusou o arquivo: %1$s'},
    "su_issue_install_older_sdk": {"de": 'Der Fernseher hat den Startbildschirm als zu neu für seine Android-Version abgelehnt. Sonst wurde nichts geändert.', "es": 'La TV rechazó la pantalla de inicio por ser demasiado nueva para su versión de Android. No se cambió nada más.', "fr": 'La TV a refusé l’écran d’accueil, trop récent pour sa version d’Android. Rien d’autre n’a été modifié.', "it": 'La TV ha rifiutato la schermata Home perché troppo recente per la sua versione di Android. Nient’altro è stato modificato.', "pt-BR": 'A TV recusou a tela inicial por ser nova demais para a versão do Android dela. Nada mais foi alterado.'},
    "su_issue_install_refused": {"de": 'Der Fernseher hat die Installation des Startbildschirms abgelehnt: %1$s', "es": 'La TV se negó a instalar la pantalla de inicio: %1$s', "fr": 'La TV a refusé d’installer l’écran d’accueil : %1$s', "it": 'La TV ha rifiutato di installare la schermata Home: %1$s', "pt-BR": 'A TV recusou instalar a tela inicial: %1$s'},
    "su_issue_theme_refused": {"de": 'Der Fernseher hat das Home-Layout abgelehnt: %1$s', "es": 'La TV rechazó el diseño de Inicio: %1$s', "fr": 'La TV a refusé la disposition de l’accueil : %1$s', "it": 'La TV ha rifiutato il layout della Home: %1$s', "pt-BR": 'A TV recusou o layout da tela inicial: %1$s'},
    "su_skip_input_check_hung": {"de": 'Die Systemdiagnose des Fernsehers ist nach einem Hänger abgeschaltet, daher kann die Eingabetreiber-Prüfung sie nicht lesen. Starte den Fernseher neu und versuche es erneut.', "es": 'El diagnóstico del sistema de la TV se desactivó tras un bloqueo, así que la comprobación del controlador de entrada no puede leerlo. Reinicia la TV y vuelve a intentarlo.', "fr": 'Les diagnostics système de la TV sont désactivés après un blocage, la vérification du pilote d’entrée ne peut donc pas les lire. Redémarrez la TV et réessayez.', "it": 'La diagnostica di sistema della TV è disattivata dopo un blocco, quindi il controllo del driver di input non può leggerla. Riavvia la TV e riprova.', "pt-BR": 'O diagnóstico do sistema da TV foi desligado após um travamento, então a verificação do driver de entrada não consegue lê-lo. Reinicie a TV e tente de novo.'},
    "su_skip_input_check_unreadable": {"de": 'Diese Firmware zeigt ihre Berechtigungen nicht an, daher kann die Eingabetreiber-Prüfung sie nicht lesen. Zur Sicherheit bleibt sie aktiviert.', "es": 'Este firmware no muestra sus permisos, así que la comprobación del controlador de entrada no puede leerlo. Se queda activada por seguridad.', "fr": 'Ce firmware n’affiche pas ses autorisations, la vérification du pilote d’entrée ne peut donc pas les lire. Elle reste activée par sécurité.', "it": 'Questo firmware non mostra i suoi permessi, quindi il controllo del driver di input non può leggerli. Resta attivata per sicurezza.', "pt-BR": 'Este firmware não mostra as permissões, então a verificação do driver de entrada não consegue lê-lo. Fica ativado por segurança.'},
    "key_volume_down": {"de": "Leiser", "es": "Bajar volumen", "fr": "Volume −", "it": "Volume giù", "pt-BR": "Diminuir volume"},
}

def android_to_ios(text):
    t = text.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
    t = re.sub(r"%(\d+\$)?s", "%@", t)
    return re.sub(r"%(\d+\$)?d", "%lld", t)

def ios_to_android(text):
    n = [0]
    def pos(m, kind):
        if m.group(1): return f"%{m.group(1)}{kind}"
        n[0] += 1; return f"%{n[0]}${kind}"
    text = re.sub(r"%(\d+\$)?@", lambda m: pos(m, "s"), text)
    text = re.sub(r"%(\d+\$)?lld", lambda m: pos(m, "d"), text)
    return escape(text).replace("'", "\\'").replace('"', '\\"').replace("\n", "\\n")

CATALOG = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "ios/Resources/Localizable.xcstrings"
catalog = json.load(open(CATALOG))["strings"]
missing = []
# Every values/strings*.xml gets its translated twin (strings.xml, strings_setup.xml, ...).
for source in sorted((RES / "values").glob("strings*.xml")):
  english = [(e.get("name"), "".join(e.itertext())) for e in ET.parse(source).getroot() if e.tag == "string"]
  for lang, folder in LANGS.items():
      lines = []
      for name, text in english:
          if name == "app_name": continue
          key = android_to_ios(text)
          phone = key.replace("phone", "iPhone").replace("iiPhone", "iPhone")
          # The iPhone's error texts have no final period; Android's do.
          candidates = [key, phone] + [k[:-1] for k in (key, phone) if k.endswith(".")]
          # Apostrophes and quotes may be straight on one side and typographic on the other.
          candidates += [c.replace("'", "’") for c in candidates] + [c.replace("’", "'").replace("“", '"').replace("”", '"') for c in candidates]
          value = None
          # A number shown as text on Android (%s) may be %lld on the iPhone.
          numbered = [c.replace("%@", "%lld", 1) for c in candidates if "%@" in c] + [c.replace("%@", "%lld") for c in candidates if "%@" in c]
          for k in candidates + numbered:
              unit = catalog.get(k, {}).get("localizations", {}).get(lang, {}).get("stringUnit")
              if unit and unit.get("value"):
                  value = unit["value"]
                  if k in numbered: value = value.replace("%lld", "%@")
                  if key.endswith(".") and not k.endswith(".") and not value.endswith("."): value += "."
                  if "iPhone" in k and "iPhone" not in key:
                      for a, b in PHONE[lang]: value = value.replace(a, b)
                  value = ios_to_android(value)
                  break
          if value is None and name in ANDROID_ONLY:
              value = re.sub(r"&(?![a-z]+;)", "&amp;", ANDROID_ONLY[name][lang]).replace("'", "\\'")
          if value is None:
              missing.append(f"{lang}:{name}"); continue
          lines.append(f'    <string name="{name}">{value}</string>')
      out = RES / f"values-{folder}"
      out.mkdir(exist_ok=True)
      (out / source.name).write_text('<?xml version="1.0" encoding="utf-8"?>\n<!-- Generated by scripts/android-strings.py; don\'t edit. -->\n<resources>\n'
                                       + "\n".join(lines) + "\n</resources>\n")
print("missing:", " ".join(missing) if missing else "none")
sys.exit(1 if missing else 0)
