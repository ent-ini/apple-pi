export default function piDesktopNotifyExtension(pi) {
  const sanitize = (value, fallback = "") => {
    const text = String(value ?? "")
      .replace(/[\u0000-\u001f\u007f]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    return text || fallback;
  };

  const writeNotification = (title, message) => {
    const safeTitle = sanitize(title, "Pi");
    const safeMessage = sanitize(message);
    if (!safeMessage) return;

    process.stdout.write(`\x1b]777;notify;${safeTitle};${safeMessage}\x07`);
  };

  pi.on("agent_end", async () => {
    writeNotification("Pi", "Ready for input");
  });

  pi.on("permissions:ask", async (event) => {
    const toolName = event?.toolName ?? event?.permission?.toolName ?? "tool";
    writeNotification("Pi", `Permission required: ${toolName}`);
  });
}
