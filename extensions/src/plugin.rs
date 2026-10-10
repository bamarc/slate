//! Plugin trait for extending Slate applications.

use std::any::Any;

pub trait Plugin: Send + Sync + 'static {
    /// Return the unique name of this plugin
    fn name(&self) -> &'static str;

    /// Called during application initialization
    fn init(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }

    /// Cast to Any for downcasting
    fn as_any(&self) -> &dyn Any;
}

#[derive(Default)]
pub struct PluginRegistry {
    plugins: Vec<Box<dyn Plugin>>,
}

impl PluginRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register<P: Plugin>(&mut self, mut plugin: P) -> Result<(), Box<dyn std::error::Error>> {
        plugin.init()?;
        self.plugins.push(Box::new(plugin));
        Ok(())
    }

    pub fn get<P: Plugin>(&self) -> Option<&P> {
        for plugin in &self.plugins {
            if let Some(downcasted) = plugin.as_any().downcast_ref::<P>() {
                return Some(downcasted);
            }
        }
        None
    }
}
