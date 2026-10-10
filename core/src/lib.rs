//! Slate Core Runtime
//!
//! Provides background task coordination, theme state management,
//! and UI event integration for high-performance applications.

pub mod task;
pub mod theme;

pub use task::*;
pub use theme::*;
