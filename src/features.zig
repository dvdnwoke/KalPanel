pub const Feature = enum {
    domain,
    email,
    php,
    node,
    // add more as needed
};

pub const FeatureSet = struct {
    domain: bool = false,
    email: bool = false,
    php: bool = false,
    node: bool = false,

    pub fn isEnabled(self: FeatureSet, f: Feature) bool {
        return switch (f) {
            .domain => self.domain,
            .email => self.email,
            .php => self.php,
            .node => self.node,
        };
    }

    pub fn fromUserFeatures(features: []const Feature) FeatureSet {
        var set = FeatureSet{};
        for (features) |f| {
            switch (f) {
                .domain => set.domain = true,
                .email => set.email = true,
                .php => set.php = true,
                .node => set.node = true,
            }
        }
        return set;
    }
};
