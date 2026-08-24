#!/bin/sh
set -eu

saved=/pal/Package/Pal/Saved
settings="$saved/Config/LinuxServer/PalWorldSettings.ini"
password="${PALWORLD_ADMIN_PASSWORD:?PALWORLD_ADMIN_PASSWORD is required}"

if [ "${#password}" -lt 24 ]; then
  echo "PALWORLD_ADMIN_PASSWORD must contain at least 24 characters" >&2
  exit 1
fi
case "$password" in
  *[!A-Za-z0-9._~!@#%^+=:-]*)
    echo "PALWORLD_ADMIN_PASSWORD contains unsupported INI characters" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$settings")"
if [ ! -s "$settings" ]; then
  cp /pal/Package/DefaultPalWorldSettings.ini "$settings"
fi

escaped_password=$(printf '%s' "$password" | sed 's/[&|]/\\&/g')
rendered="$settings.rendered"
sed -E \
  -e "s|AdminPassword=\"[^\"]*\"|AdminPassword=\"$escaped_password\"|" \
  -e 's,RCONEnabled=(True|False),RCONEnabled=False,' \
  -e 's,RESTAPIEnabled=(True|False),RESTAPIEnabled=True,' \
  -e 's,RESTAPIPort=[0-9]+,RESTAPIPort=8212,' \
  "$settings" > "$rendered"

grep -Fq "AdminPassword=\"$password\"" "$rendered"
grep -Fq 'RCONEnabled=False' "$rendered"
grep -Fq 'RESTAPIEnabled=True' "$rendered"
grep -Fq 'RESTAPIPort=8212' "$rendered"
mv "$rendered" "$settings"

exec /bin/sh /pal/Package/PalServer.sh "$@"
