//! Legacy Redis/Findex migration errors have been removed.
#![allow(dead_code)]

pub(crate) type LegacyDbResult<R> = Result<R, String>;

#[derive(Debug)]
pub enum LegacyDbError {}
