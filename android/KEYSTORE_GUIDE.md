# Guía de keystore — Oír Pro

> Spec `oir-pro-rebrand-harden-and-remote-config`, Fase 4 (R4.1 a R4.6).
>
> Este documento es para vos, Henry. Lo seguís una sola vez para
> generar la keystore y dejar configurados los GitHub Secrets. Después
> el workflow `build-apk.yml` firma todas las APKs solo.

## 1. Qué es la keystore y por qué importa

La **keystore** (`.jks`) es un archivo con la clave criptográfica que
firma la APK. Android usa esa firma como identidad de la app:

- Si una APK firmada con la keystore A intenta sobrescribir una APK
  firmada con la keystore B, Android rechaza el update.
- Sirve para que nadie pueda distribuir una APK "como Oír Pro" si no
  tiene la keystore — el celular del usuario va a rechazar el update.
- Si perdés la keystore o las contraseñas, **no podés volver a hacer
  updates** de la app instalada en celulares: Android no va a aceptar
  ninguna APK con firma distinta.

Hoy la APK se firma con la **debug key** que Flutter genera
automáticamente. Cualquiera que tenga el código fuente puede generar
una APK con la misma debug key y reemplazar la app en un celular. Por
eso en Fase 4 movemos la firma a una keystore propia, guardada solo en
tu PC y en GitHub Secrets.

## 2. Generar la keystore

Abrí una terminal en una carpeta segura **fuera del repo** (por ejemplo
`C:\Users\Elsa y Henry\Documents\OirProKeys\`) y corré:

```
keytool -genkey -v -keystore oirpro-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias oirpro
```

`keytool` viene con Java. Si te dice "comando no reconocido", está en
`C:\Program Files\Java\jdk-17\bin\keytool.exe` o similar — agregá esa
carpeta al PATH o llamalo con la ruta completa.

El comando va a pedirte:

1. **Contraseña del keystore** — pass del archivo `.jks` completo.
2. **Datos del owner**: nombre y apellido, unidad, organización, ciudad,
   provincia, código de país (AR). Podés poner lo que quieras, no se
   muestra al usuario final, pero queda guardado para siempre dentro de
   la APK.
3. **Contraseña de la key con alias `oirpro`** — si te pregunta si
   querés usar la misma del keystore, podés. Las dos contraseñas pueden
   ser iguales o distintas; el workflow las maneja por separado.

> **Crítico:** anotá las dos contraseñas y los datos del owner en un
> lugar seguro (gestor de contraseñas, libreta física, lo que uses).
> Perderlas = no más updates de Oír Pro nunca más, jamás. Todos los
> celulares con la app instalada quedan congelados en la última versión
> que les llegó. La única salida sería desinstalar manualmente cada
> celular y reinstalar con keystore nueva, perdiendo settings.

Al terminar te queda `oirpro-release.jks` en la carpeta. Validá con:

```
keytool -list -v -keystore oirpro-release.jks -alias oirpro
```

Te tiene que mostrar el certificado con SHA-1, SHA-256 y la validez
de ~27 años (10000 días).

## 3. Convertir el `.jks` a base64 para subirlo como secret

GitHub Secrets guarda strings, no archivos binarios. Convertimos el
`.jks` a base64 con `certutil` (viene con Windows):

```
certutil -encode oirpro-release.jks oirpro-release.b64
```

Eso genera `oirpro-release.b64`. Abrilo con un editor de texto (Notepad
está bien) y borrá las dos líneas del header y el footer:

```
-----BEGIN CERTIFICATE-----   ← borrá esta línea
<contenido base64 — esto SÍ se queda>
-----END CERTIFICATE-----     ← borrá esta línea
```

El archivo final debe contener **solo el bloque base64**, sin BEGIN ni
END. Guardalo.

## 4. Subir los GitHub Secrets

En el navegador, andá al repo `memomedix3-commits/Audifono`:

```
https://github.com/memomedix3-commits/Audifono/settings/secrets/actions
```

(`Settings` → `Secrets and variables` → `Actions` → `New repository
secret`).

Creá los cuatro secrets:

| Secret name | Valor |
|---|---|
| `KEYSTORE_BASE64` | contenido completo del `.b64` (sin BEGIN/END) |
| `KEYSTORE_PASSWORD` | contraseña del keystore |
| `KEY_ALIAS` | `oirpro` |
| `KEY_PASSWORD` | contraseña de la key alias `oirpro` |

Guardá cada uno con `Add secret`. Una vez guardados, GitHub no te los
deja leer de nuevo (son write-only desde la UI), así que asegurate de
que estén bien escritos antes de guardarlos.

## 5. Verificar que el workflow firma con la keystore nueva

Pusheá un cambio cualquiera a `main` y dejá que el workflow `Build APK`
corra. Bajá la APK de Releases y verificá la firma con `apksigner`:

```
apksigner verify --print-certs oir-pro.apk
```

(`apksigner` viene con el Android SDK build-tools, en
`%LOCALAPPDATA%\Android\Sdk\build-tools\<version>\apksigner.bat`).

Tiene que mostrar el SHA-256 del certificado que generaste, no el
SHA-256 de la debug key de Flutter (`AndroidDebugKey`). Si ves
`CN=Android Debug`, los secrets no se cargaron y el workflow firmó con
la debug — revisá el log del paso `Validate keystore secrets`.

## 6. Reglas críticas

- **NUNCA** commitees el archivo `oirpro-release.jks` al repo.
- **NUNCA** commitees el archivo `oirpro-release.b64` al repo.
- **NUNCA** commitees el archivo `key.properties` al repo.
- El `.gitignore` de `android/` ya tiene esos patrones, pero verificá
  con `git status` antes de cada commit que no aparecen.
- Si por error subís el `.jks` o las contraseñas a un repo público,
  considerá la keystore comprometida: regenerá una nueva keystore,
  reemplazá los GitHub Secrets, y desde ese momento las nuevas APKs
  van a tener firma distinta — los celulares con la app instalada
  van a necesitar desinstalar / reinstalar manualmente.
- Hacé un backup del `.jks` y las contraseñas en un disco externo o
  servicio cifrado. Si te quedás sin la keystore, la app muere.
