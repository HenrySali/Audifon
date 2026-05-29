# Cómo hacer Push al repositorio del Audífono

## Repositorio
- **URL:** https://github.com/henrysalinas1985-source/audifono.git
- **Rama:** main

---

## Problema

La ruta del proyecto tiene espacios ("Elsa y Henry", "Nueva carpeta") lo cual causa
problemas en la terminal de Kiro y en PowerShell cuando los comandos son largos.

---

## Solución: Usar el script .bat

### Ubicación del script
```
c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\.kiro_tmp\git-push.bat
```

### Contenido del script (editar el mensaje antes de ejecutar)
```bat
@echo off
set REPO=c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\Amplificador\hearing_aid_app
git -C "%REPO%" add -A
git -C "%REPO%" commit -m "ESCRIBIR MENSAJE AQUI"
git -C "%REPO%" push origin main
```

### Cómo ejecutar desde Kiro
```
cmd /c "c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\.kiro_tmp\git-push.bat"
```

### Cómo ejecutar desde CMD (Windows)
```cmd
"c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\.kiro_tmp\git-push.bat"
```

### Cómo ejecutar desde PowerShell
```powershell
cmd /c '"c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\.kiro_tmp\git-push.bat"'
```

---

## Alternativa: Comandos manuales desde CMD

Si prefieres no usar el script, abre CMD (no PowerShell) y ejecuta:

```cmd
set REPO=c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\Amplificador\hearing_aid_app

git -C "%REPO%" add -A
git -C "%REPO%" commit -m "tu mensaje aqui"
git -C "%REPO%" push origin main
```

**IMPORTANTE:** Usar CMD, no PowerShell. En CMD las comillas con `%REPO%` funcionan bien.

---

## Alternativa: Navegar a la carpeta primero

```cmd
cd "c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\Amplificador\hearing_aid_app"
git add -A
git commit -m "tu mensaje"
git push origin main
```

---

## Ver los últimos commits

```cmd
set REPO=c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\Amplificador\hearing_aid_app
git -C "%REPO%" log --oneline -5
```

O usar el script:
```
c:\Users\Elsa y Henry\Pictures\Nueva carpeta\API\.kiro_tmp\git-log.bat
```

---

## Notas

- El script `.bat` usa `set REPO=...` para guardar la ruta en una variable y evitar problemas con espacios
- Siempre editar el mensaje del commit en el `.bat` antes de ejecutar
- Si dice "nothing to commit" es porque ya se hizo push antes
- Si dice "Everything up-to-date" es porque no hay cambios nuevos
- El repositorio usa autenticación por HTTPS (credenciales guardadas en Windows Credential Manager)
