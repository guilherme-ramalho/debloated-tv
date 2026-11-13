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
    "key_volume_down": {"de": "Leiser", "es": "Bajar volumen", "fr": "Volume −", "it": "Volume giù", "pt-BR": "Diminuir volume"},
}

def android_to_ios(text):
    t = text.replace("\\'", "'").replace('\\"', '"')
    t = re.sub(r"%(\d+\$)?s", "%@", t)
    return re.sub(r"%(\d+\$)?d", "%lld", t)

def ios_to_android(text):
    n = [0]
    def pos(m, kind):
        if m.group(1): return f"%{m.group(1)}{kind}"
        n[0] += 1; return f"%{n[0]}${kind}"
    text = re.sub(r"%(\d+\$)?@", lambda m: pos(m, "s"), text)
    text = re.sub(r"%(\d+\$)?lld", lambda m: pos(m, "d"), text)
    return escape(text).replace("'", "\\'").replace('"', '\\"')

CATALOG = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "ios/Resources/Localizable.xcstrings"
catalog = json.load(open(CATALOG))["strings"]
english = [(e.get("name"), "".join(e.itertext())) for e in ET.parse(RES / "values/strings.xml").getroot() if e.tag == "string"]
missing = []
for lang, folder in LANGS.items():
    lines = []
    for name, text in english:
        if name == "app_name": continue
        key = android_to_ios(text)
        phone = key.replace("phone", "iPhone").replace("iiPhone", "iPhone")
        # The iPhone's error texts have no final period; Android's do.
        candidates = [key, phone] + [k[:-1] for k in (key, phone) if k.endswith(".")]
        value = None
        for k in candidates:
            unit = catalog.get(k, {}).get("localizations", {}).get(lang, {}).get("stringUnit")
            if unit and unit.get("value"):
                value = unit["value"]
                if key.endswith(".") and not k.endswith(".") and not value.endswith("."): value += "."
                if "iPhone" in k and "iPhone" not in key:
                    for a, b in PHONE[lang]: value = value.replace(a, b)
                value = ios_to_android(value)
                break
        if value is None and name in ANDROID_ONLY:
            value = ANDROID_ONLY[name][lang].replace("'", "\\'")
        if value is None:
            missing.append(f"{lang}:{name}"); continue
        lines.append(f'    <string name="{name}">{value}</string>')
    out = RES / f"values-{folder}"
    out.mkdir(exist_ok=True)
    (out / "strings.xml").write_text('<?xml version="1.0" encoding="utf-8"?>\n<!-- Generated by scripts/android-strings.py; don\'t edit. -->\n<resources>\n'
                                     + "\n".join(lines) + "\n</resources>\n")
print("missing:", " ".join(missing) if missing else "none")
sys.exit(1 if missing else 0)
