#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resource_root="$source_dir/lang"
bundle_root="${1:-}"
localization_directories=(en.lproj zh-Hans.lproj zh-Hant-TW.lproj zh-Hant-HK.lproj ja.lproj ko.lproj es.lproj de.lproj fr.lproj pt.lproj ru.lproj it.lproj)

die() {
    printf 'localization-resource-probe: error: %s\n' "$*" >&2
    exit 1
}

source_keys="$(
    sed -nE 's/^    case .* = "([^"]+)".*/\1/p' "$source_dir/Sources/AppCore/LocalizationKeys.swift" \
        | LC_ALL=C sort
)"
source_key_count="$(printf '%s\n' "$source_keys" | awk 'NF { count += 1 } END { print count + 0 }')"
source_unique_count="$(printf '%s\n' "$source_keys" | LC_ALL=C uniq | awk 'NF { count += 1 } END { print count + 0 }')"
[[ "$source_key_count" == "$source_unique_count" ]] || die "LocalizationKey contains duplicate raw keys"

for localization_directory in "${localization_directories[@]}"; do
    localization_file="$resource_root/$localization_directory/Localizable.strings"
    [[ -f "$localization_file" ]] || die "source resource is missing: $localization_file"

    resource_keys="$(
        sed -nE 's/^"([^"]+)".*/\1/p' "$localization_file" \
            | LC_ALL=C sort
    )"
    resource_key_count="$(printf '%s\n' "$resource_keys" | awk 'NF { count += 1 } END { print count + 0 }')"
    resource_unique_count="$(printf '%s\n' "$resource_keys" | LC_ALL=C uniq | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$resource_key_count" == "$source_key_count" ]] \
        || die "$localization_directory has $resource_key_count keys; expected $source_key_count"
    [[ "$resource_key_count" == "$resource_unique_count" ]] \
        || die "$localization_directory contains duplicate keys"
    [[ "$resource_keys" == "$source_keys" ]] \
        || die "$localization_directory key set differs from LocalizationKey"

    case "$localization_directory" in
        pt.lproj)
            forbidden_pattern="Tibo's|AbrirAI|Abrir o status da OpenAI|Para cimadates|^Do não mostrar$|Reserva Luna|Intervalo de verificação de backup|Redefine em %1\$@|Escolha se deseja verificar as versões Estável|evita eventos do sistema perdidos|As alterações de provedor são sincronizadas imediatamente|Hora da redefinição|Após uma recarga, mantém|Segue o CC Switch automaticamente|Seguir o sistema|Seguindo este provedor|Seguindo o provedor atual|Este provedor está em uso|O provedor atual está em uso|Follows CC Switch automatically|Official cota|Too many|Restore Defaults|Quick links|Preview|Font Size|Vertical position|main window|Changes apply|No live data|received yet|OpenCodex switch|database verification|Unrecognized|Contact .*maintainer|Every [0-9]"
            ;;
        ru.lproj)
            forbidden_pattern="Tibo's|Вверхdates|ОткрытьAI|Открыть статус OpenAI|Резерв Luna|Доступно провайдер|Следит за|Следовать системе|Автоматически следует за CC Switch|Используется этот провайдер|Используется текущий провайдер|%1\$@ остаток|от -10,0 pt уже|Интервал резервной проверки|синхронизируются событиями|больше недоступен в CC Switch|Через [0-9]+ с|Follows CC Switch automatically|Official квота|Too many|Restore Defaults|Quick links|Preview|Font Size|Vertical position|main window|Changes apply|No live data|received yet|OpenCodex switch|database verification|Unrecognized|Contact .*maintainer|Every [0-9]"
            ;;
        it.lproj)
            forbidden_pattern="Tibo's|Sudates|ApriAI|Apri lo stato di OpenAI|Riserva Luna|^Ufficiale %|Attuale provider|Disponibile provider|Stato sincronizzazione|Ora del ripristino Visualizzazione|Ora del ripristino non disponibile|Intervallo di verifica di riserva|controllo di riserva|vengono sincronizzate immediatamente dagli eventi|Dopo una ricarica, mantiene rossa|versioni Stabile o Beta|Segue automaticamente CC Switch|Segui il sistema|Segue questo provider|Segue il provider corrente|Questo provider è in uso|Il provider corrente è in uso|Follows CC Switch automatically|Official quota|Too many|Restore Defaults|Quick links|Preview|Font Size|Vertical position|main window|Changes apply|No live data|received yet|OpenCodex switch|database verification|Unrecognized|Contact .*maintainer|Every [0-9]"
            ;;
        *)
            forbidden_pattern=""
            ;;
    esac
    if [[ -n "$forbidden_pattern" ]] \
        && sed -nE 's/^"[^"]+" = "(.*)";$/\1/p' "$localization_file" \
            | grep -Eiq "$forbidden_pattern"; then
        die "$localization_directory contains suspicious hybrid or mechanically corrupted translation text"
    fi
done

if [[ -n "$bundle_root" ]]; then
    resources_dir="$bundle_root/Contents/Resources"
    [[ -d "$resources_dir" ]] || die "bundle Resources directory is missing: $resources_dir"
    for localization_directory in "${localization_directories[@]}"; do
        packaged_file="$resources_dir/$localization_directory/Localizable.strings"
        [[ -s "$packaged_file" ]] \
            || die "packaged resource is missing or empty: $packaged_file"
    done
fi

printf 'localization-resource-probe: PASS (%s keys, %s languages' "$source_key_count" "${#localization_directories[@]}"
if [[ -n "$bundle_root" ]]; then
    printf ', bundle=%s' "$bundle_root"
fi
printf ')\n'
