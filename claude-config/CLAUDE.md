# Git: nunca firmar commits/tags con GPG

Este sistema tiene configurado globalmente en `~/.gitconfig`:

```
[commit]
	gpgsign = true
[tag]
	gpgSign = true
```

con `user.signingkey = AF043CAC6ED816FF`.

**Problema:** cuando Claude Code ejecuta `git commit` o `git tag` en una shell no
interactiva, `gpg`/`pinentry` no tiene una TTY donde pedir el passphrase. El proceso
se queda colgado indefinidamente, el comando nunca devuelve resultado y la terminal
queda rota/inutilizable.

**Solución obligatoria:** al crear commits o tags, agregar siempre `--no-gpg-sign` /
`--no-sign`, por ejemplo:

```bash
git commit --no-gpg-sign -m "mensaje"
git tag --no-sign nombre-del-tag
```

(equivalente: `git -c commit.gpgsign=false commit ...`)

Esto aplica en **cualquier repositorio**, no solo en este. El usuario ya dio permiso
explícito y permanente para omitir la firma GPG por este motivo — no es necesario
volver a pedir confirmación.
