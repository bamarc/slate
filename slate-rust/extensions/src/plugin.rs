//! Plugin trait for extending Slate applications.

use std::any::Any;
use std::fmt;

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

/// Errors returned by [`PluginRegistry::register`] besides plugin init failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PluginError {
    /// A plugin with this name is already registered.
    Duplicate(&'static str),
}

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Duplicate(name) => write!(f, "plugin '{name}' is already registered"),
        }
    }
}

impl std::error::Error for PluginError {}

#[derive(Default)]
pub struct PluginRegistry {
    plugins: Vec<Box<dyn Plugin>>,
}

impl PluginRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers a plugin after a successful `init`. Names must be unique;
    /// a duplicate or failing plugin is not registered.
    pub fn register<P: Plugin>(&mut self, mut plugin: P) -> Result<(), Box<dyn std::error::Error>> {
        let name = plugin.name();
        if self.get_by_name(name).is_some() {
            return Err(Box::new(PluginError::Duplicate(name)));
        }
        plugin.init()?;
        self.plugins.push(Box::new(plugin));
        Ok(())
    }

    pub fn get<P: Plugin>(&self) -> Option<&P> {
        self.plugins
            .iter()
            .find_map(|plugin| plugin.as_any().downcast_ref::<P>())
    }

    pub fn get_by_name(&self, name: &str) -> Option<&dyn Plugin> {
        self.plugins
            .iter()
            .find(|p| p.name() == name)
            .map(|p| p.as_ref())
    }

    pub fn len(&self) -> usize {
        self.plugins.len()
    }

    pub fn is_empty(&self) -> bool {
        self.plugins.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct A(u32);
    impl Plugin for A {
        fn name(&self) -> &'static str {
            "a"
        }
        fn as_any(&self) -> &dyn Any {
            self
        }
    }

    struct Failing;
    impl Plugin for Failing {
        fn name(&self) -> &'static str {
            "failing"
        }
        fn init(&mut self) -> Result<(), Box<dyn std::error::Error>> {
            Err("nope".into())
        }
        fn as_any(&self) -> &dyn Any {
            self
        }
    }

    #[test]
    fn register_and_lookup() {
        let mut r = PluginRegistry::new();
        r.register(A(5)).unwrap();
        assert_eq!(r.get::<A>().unwrap().0, 5);
        assert_eq!(r.get_by_name("a").unwrap().name(), "a");
        assert!(r.get_by_name("zzz").is_none());
        assert!(r.get::<Failing>().is_none());
    }

    #[test]
    fn duplicate_name_rejected() {
        let mut r = PluginRegistry::new();
        r.register(A(1)).unwrap();
        let err = r.register(A(2)).unwrap_err();
        assert_eq!(err.downcast_ref::<PluginError>(), Some(&PluginError::Duplicate("a")));
        assert_eq!(r.len(), 1);
        assert_eq!(r.get::<A>().unwrap().0, 1);
    }

    #[test]
    fn failed_init_not_registered() {
        let mut r = PluginRegistry::new();
        assert!(r.register(Failing).is_err());
        assert!(r.is_empty());
        assert!(r.get_by_name("failing").is_none());
    }
}
