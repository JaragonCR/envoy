# Enphase Envoy Local - SmartThings Edge Driver

A SmartThings Edge LAN driver to locally integrate Enphase Envoy solar gateways running Firmware 7.x or newer. 

Unlike cloud-to-cloud integrations, this driver communicates directly with your Envoy over your local network. Due to Enphase's firmware updates, local communication now requires a JSON Web Token (JWT) for authentication.

## Features
* **Local LAN Control:** No reliance on the SmartThings or Enphase clouds for polling.
* **Live Power (Watts):** Reports real-time solar production.
* **Daily Energy (kWh):** Reports total energy produced for the current day.
* **Automatic Polling:** Built-in polling loop refreshes data every 5 minutes.

## Prerequisites
1. A SmartThings Hub (v2, v3, or Aeotec) on the same local network as your Envoy.
2. The local IPv4 address of your Envoy (e.g., `192.168.1.50`). Setting a static IP in your router is highly recommended.
3. An Enphase API Token (instructions below).

---

## How to Obtain Your Enphase API Token (Firmware 7.x+)

Enphase requires a token to authorize local network requests. As the system owner, you can generate a token that is valid for **1 year**. You will need to repeat this process annually to keep the driver working.

1. Navigate to the Enphase Entrez portal: [entrez.enphaseenergy.com](https://entrez.enphaseenergy.com/)
2. Log in using the same email and password you use for the standard Enphase mobile app.
3. In the **Select System** field, begin typing your system's name exactly as it appears in the Enphase app (usually your name or street address). It acts as a search bar.
4. Once your system is selected, click the **Select Gateway** dropdown. It should now be populated with your Envoy's serial number. Select it.
5. Click **Generate Token**.
6. A large block of text will appear. This is your JWT Token. Copy this entire block of text to your clipboard.

---

## Installation & Setup

### 1. Package and Install the Driver
Use the SmartThings CLI to package the driver and assign it to your hub:
\`\`\`bash
smartthings edge:drivers:package
\`\`\`
Follow the CLI prompts to select your hub and channel.

### 2. Add the Device in SmartThings
1. Open the SmartThings app on your phone.
2. Go to the **Devices** tab and tap the **+** (plus) icon in the top right.
3. Tap **Add device**, then scroll down and tap **Scan for nearby devices**.
4. The hub will execute the discovery protocol, and a new device named **Enphase Envoy** will appear in your room.

### 3. Configure the Device
1. Open the newly created **Enphase Envoy** device in the SmartThings app.
2. Tap the three dots (`⋮`) in the top right corner and select **Settings**.
3. **Envoy IP Address:** Enter the local IP address of your Envoy.
4. **Enphase API Token:** Paste the massive token string you copied from the Entrez portal.
5. Save your settings. The driver will immediately attempt to connect and pull your latest solar data!