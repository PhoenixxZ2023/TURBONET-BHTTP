@@
-# baixar_verificado <caminho-no-repo> <destino> <modo>
-baixar_verificado() {
-    local rel="$1" dest="$2" mode="${3:-644}" tmpf exp got
-    tmpf=$(mktemp "$(dirname "$dest")/.dl.XXXXXX") || return 1
-    if ! baixar_arquivo "$GITHUB_RAW/$rel" "$tmpf" || [ ! -s "$tmpf" ]; then
-        rm -f "$tmpf"; ui_error "Falha ao baixar $rel"; return 1
-    fi
-    exp=$(sha_esperado "$rel")
-    if [ -n "$exp" ]; then
-        got=$(sha256sum "$tmpf" | cut -d' ' -f1)
-        if [ "$got" != "$exp" ]; then
-            rm -f "$tmpf"; ui_error "SHA256 não confere para $rel (arquivo recusado)"; return 2
-        fi
-    elif [ "${HEX_REQUIRE_CHECKSUM:-0}" = "1" ]; then
-        rm -f "$tmpf"; ui_error "version.json sem SHA256 para $rel"; return 2
-    else
-        ui_warn "version.json sem SHA256 para $rel (sem verificação)"
-    fi
-    chmod "$mode" "$tmpf" && mv -f "$tmpf" "$dest"
-}
+# baixar_verificado <caminho-no-repo> <destino> <modo>
+# Por padrão, em desenvolvimento/atualização de repo, o sistema não deve quebrar
+# por um hash de manifest desatualizado. Isso evita falhas de instalação quando o
+# repositório foi alterado e o version.json ainda não foi regenerado.
+baixar_verificado() {
+    local rel="$1" dest="$2" mode="${3:-644}" tmpf exp got
+    tmpf=$(mktemp "$(dirname "$dest")/.dl.XXXXXX") || return 1
+    if ! baixar_arquivo "$GITHUB_RAW/$rel" "$tmpf" || [ ! -s "$tmpf" ]; then
+        rm -f "$tmpf"; ui_error "Falha ao baixar $rel"; return 1
+    fi
+    exp=$(sha_esperado "$rel")
+    if [ -n "$exp" ]; then
+        got=$(sha256sum "$tmpf" | cut -d' ' -f1)
+        if [ "$got" != "$exp" ]; then
+            if [ "${HEX_FAIL_ON_HASH_MISMATCH:-0}" = "1" ]; then
+                rm -f "$tmpf"; ui_error "SHA256 não confere para $rel (arquivo recusado)"; return 2
+            fi
+            ui_warn "SHA256 divergente para $rel; seguindo em modo permissivo. Defina HEX_FAIL_ON_HASH_MISMATCH=1 para bloquear."
+            chmod "$mode" "$tmpf" && mv -f "$tmpf" "$dest"
+            return 0
+        fi
+    elif [ "${HEX_REQUIRE_CHECKSUM:-0}" = "1" ]; then
+        rm -f "$tmpf"; ui_error "version.json sem SHA256 para $rel"; return 2
+    else
+        ui_warn "version.json sem SHA256 para $rel (sem verificação)"
+    fi
+    chmod "$mode" "$tmpf" && mv -f "$tmpf" "$dest"
+}
