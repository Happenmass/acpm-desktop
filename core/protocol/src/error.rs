use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    InvalidRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    AudioValidationFailed,
    ModelNotInstalled,
    UnsupportedPlatform,
    InsufficientMemory,
    SchedulerBusy,
    QueueTimeout,
    WorkerCrashed,
    InferenceFailed,
    Cancelled,
    NotImplemented,
}

impl ErrorCode {
    pub fn http_status(&self) -> u16 {
        match self {
            Self::InvalidRequest | Self::AudioValidationFailed => 400,
            Self::Unauthorized => 401,
            Self::Forbidden => 403,
            Self::NotFound => 404,
            Self::Cancelled => 408,
            Self::UnsupportedPlatform => 422,
            Self::ModelNotInstalled => 424,
            Self::InferenceFailed => 500,
            Self::NotImplemented => 501,
            Self::WorkerCrashed => 502,
            Self::SchedulerBusy => 503,
            Self::QueueTimeout => 504,
            Self::InsufficientMemory => 507,
        }
    }

    pub fn default_retryable(&self) -> bool {
        matches!(
            self,
            Self::SchedulerBusy | Self::QueueTimeout | Self::WorkerCrashed
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum FailureStage {
    HttpAdmission,
    AudioValidation,
    ModelPrepare,
    SchedulerQueue,
    WorkerStart,
    WorkerIo,
    ModelLoad,
    Inference,
    ResultValidation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
    pub request_id: String,
    pub stage: FailureStage,
    pub detail: String,
    pub native_code: Option<String>,
    pub elapsed_ms: i64,
    pub retryable: bool,
}

impl ApiError {
    pub fn new(
        code: ErrorCode,
        stage: FailureStage,
        detail: impl Into<String>,
        message: impl Into<String>,
        request_id: impl Into<String>,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            request_id: request_id.into(),
            stage,
            detail: detail.into(),
            native_code: None,
            elapsed_ms: 0,
            retryable: code.default_retryable(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiErrorEnvelope {
    pub error: ApiError,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticFailure {
    pub timestamp_ms: i64,
    pub request_id: String,
    pub caller: String,
    pub model_id: Option<String>,
    pub operation: String,
    pub stage: FailureStage,
    pub code: ErrorCode,
    pub detail: String,
    pub native_code: Option<String>,
    pub elapsed_ms: i64,
    pub worker_pid: Option<u32>,
}
