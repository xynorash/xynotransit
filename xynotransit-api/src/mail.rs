//! Sending the sign-in link. SMTP in real life, an in-memory box in tests.

use std::sync::{Arc, Mutex};

use crate::config::SmtpSecurity;
use lettre::{
    message::{header::ContentType, Mailbox},
    transport::smtp::authentication::Credentials,
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};

#[derive(Debug, Clone)]
pub struct SentMail {
    pub to: String,
    pub link: String,
}

#[derive(Clone)]
pub enum Mailer {
    Smtp {
        transport: Box<AsyncSmtpTransport<Tokio1Executor>>,
        from: Mailbox,
    },
    Capture(Arc<Mutex<Vec<SentMail>>>),
}

impl Mailer {
    pub fn smtp(
        host: &str,
        port: u16,
        from: &str,
        security: SmtpSecurity,
        credentials: Option<(String, String)>,
    ) -> anyhow::Result<Self> {
        let from: Mailbox = from
            .parse()
            .map_err(|_| anyhow::anyhow!("MAIL_FROM is not a valid address"))?;
        let builder = match security {
            SmtpSecurity::None => AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host),
            SmtpSecurity::StartTls => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(host)?,
            SmtpSecurity::Tls => AsyncSmtpTransport::<Tokio1Executor>::relay(host)?,
        };
        let mut builder = builder
            .port(port)
            .timeout(Some(std::time::Duration::from_secs(10)));
        if let Some((user, pass)) = credentials {
            builder = builder.credentials(Credentials::new(user, pass));
        }
        let transport = builder.build();
        Ok(Mailer::Smtp {
            transport: Box::new(transport),
            from,
        })
    }

    pub fn capture() -> Self {
        Mailer::Capture(Arc::new(Mutex::new(Vec::new())))
    }

    /// Mails captured so far (tests only; empty for SMTP).
    pub fn sent(&self) -> Vec<SentMail> {
        match self {
            Mailer::Capture(v) => v.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            Mailer::Smtp { .. } => Vec::new(),
        }
    }

    pub async fn send_login_link(&self, to: &str, link: &str) -> Result<(), String> {
        match self {
            Mailer::Capture(v) => {
                v.lock().unwrap_or_else(|e| e.into_inner()).push(SentMail {
                    to: to.to_string(),
                    link: link.to_string(),
                });
                Ok(())
            }
            Mailer::Smtp { transport, from } => {
                let to: Mailbox = to
                    .parse()
                    .map_err(|_| "bad recipient address".to_string())?;
                let body = format!(
                    "Hello,\n\nUse this link to sign in to the Xynotransit Logistics Report Builder. \
                     It works once and expires in 15 minutes.\n\n{link}\n\n\
                     If you did not ask for it, you can ignore this email.\n"
                );
                let msg = Message::builder()
                    .from(from.clone())
                    .to(to)
                    .subject("Your Xynotransit sign-in link")
                    .header(ContentType::TEXT_PLAIN)
                    .body(body)
                    .map_err(|e| e.to_string())?;
                transport
                    .send(msg)
                    .await
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            }
        }
    }
}
